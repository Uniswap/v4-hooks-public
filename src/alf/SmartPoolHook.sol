// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SpreadQuoterBase} from "./base/SpreadQuoterBase.sol";

/// @title SmartPoolHook
/// @notice Rehypothecating spread quoter using Just-In-Time (JIT) liquidity with ERC4626 vaults.
///
///         All pool assets live in vaults earning yield between swaps. Liquidity is deployed to
///         the pool only for the duration of each swap:
///
///           beforeSwap  → withdraw from vaults, deploy concentrated LP
///           [pool executes swap against the LP]
///           afterSwap   → remove LP, re-deposit to vaults
///
///         Pricing is via SpreadQuoterBase fee overrides. The pool operator manages spreads
///         through the standard `updatePricingState` path — no hookData-based curve updates.
///         Vaults are configured at pool initialization and cannot be changed.
///
///         All asset tracking is pool-scoped: vault shares and ERC-6909 claims are isolated
///         per pool, enabling a single hook instance to serve multiple pools.
contract SmartPoolHook is SpreadQuoterBase, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // ──── Constants & Types ────

    bytes32 public constant LP_SALT = bytes32(uint256(0x534D5254)); // "SMRT"

    enum Rounding {
        Floor,
        Ceil
    }

    // ──── Per-Pool State ────

    mapping(PoolId => mapping(Currency => IERC4626)) public vaults;
    mapping(PoolId => int24) public poolTickLower;
    mapping(PoolId => int24) public poolTickUpper;
    mapping(PoolId => uint256) public totalShares;
    mapping(PoolId => mapping(address => uint256)) public userShares;
    mapping(PoolId => bool) public externalDepositsEnabled;
    mapping(PoolId => address) public poolOperator;
    mapping(PoolId => PoolKey) internal _poolKeys;
    mapping(PoolId => uint128) internal _activeJITLiquidity;
    mapping(PoolId => mapping(Currency => uint256)) internal _poolVaultShares;
    mapping(PoolId => mapping(Currency => uint256)) internal _poolClaims;
    mapping(PoolId => mapping(Currency => uint256)) internal _poolERC20;

    // ──── Events ────

    event PoolCreated(PoolId indexed poolId, int24 tickLower, int24 tickUpper, address operator);
    event LiquidityAdded(PoolId indexed poolId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(PoolId indexed poolId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);
    event TickRangeUpdated(PoolId indexed poolId, int24 tickLower, int24 tickUpper);

    // ──── Errors ────

    error LiquidityNotAllowed();
    error ExternalDepositsDisabled();
    error InsufficientShares();
    error InvalidHookAddress();
    error MustUseDynamicFee();
    error Unauthorized();

    // ──── Constructor ────

    constructor(
        IPoolManager _poolManager,
        uint32 maxGas_,
        address owner_
    ) SpreadQuoterBase(_poolManager, maxGas_, owner_, "SmartPoolHook") {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool with vaults, pricing, and operator in one call.
    /// @dev    Vaults are permanent — set at creation and cannot be changed.
    function initializePool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        PricingState calldata pricing,
        int24 tickLower,
        int24 tickUpper,
        address operator,
        bool allowExternalDeposits,
        IERC4626 vault0,
        IERC4626 vault1
    ) external onlyOwner returns (int24 tick) {
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert MustUseDynamicFee();
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower % key.tickSpacing != 0 || tickUpper % key.tickSpacing != 0) revert InvalidTickRange();

        PoolId poolId = key.toId();
        _poolKeys[poolId] = key;
        pricingState[poolId] = pricing;
        poolTickLower[poolId] = tickLower;
        poolTickUpper[poolId] = tickUpper;
        poolOperator[poolId] = operator;
        externalDepositsEnabled[poolId] = allowExternalDeposits;
        vaults[poolId][key.currency0] = vault0;
        vaults[poolId][key.currency1] = vault1;

        tick = poolManager.initialize(key, sqrtPriceX96);
        emit PoolCreated(poolId, tickLower, tickUpper, operator);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: LP DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit token0 and token1 proportional to the pool's current asset ratio.
    /// @dev    First deposit: 1 share = 1 unit of each token. Amounts rounded up (Ceil).
    function addLiquidity(PoolKey calldata key, uint256 sharesToMint)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        _requireDepositAuth(poolId);

        (amount0, amount1) = _convertSharesToAmounts(key, sharesToMint, Rounding.Ceil);

        if (amount0 > 0) IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1);

        _depositToVault(poolId, key.currency0, amount0);
        _depositToVault(poolId, key.currency1, amount1);

        totalShares[poolId] += sharesToMint;
        userShares[poolId][msg.sender] += sharesToMint;

        emit LiquidityAdded(poolId, msg.sender, sharesToMint, amount0, amount1);
    }

    /// @notice Burn shares and receive proportional token0 + token1.
    function removeLiquidity(PoolKey calldata key, uint256 sharesToBurn)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        if (userShares[poolId][msg.sender] < sharesToBurn) revert InsufficientShares();

        (amount0, amount1) = _convertSharesToAmounts(key, sharesToBurn, Rounding.Floor);

        totalShares[poolId] -= sharesToBurn;
        userShares[poolId][msg.sender] -= sharesToBurn;

        _ensureERC20Balance(poolId, key.currency0, amount0);
        _ensureERC20Balance(poolId, key.currency1, amount1);

        if (amount0 > 0) IERC20Minimal(Currency.unwrap(key.currency0)).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20Minimal(Currency.unwrap(key.currency1)).transfer(msg.sender, amount1);

        emit LiquidityRemoved(poolId, msg.sender, sharesToBurn, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: OWNER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Update the tick range for JIT liquidity deployment.
    function setTickRange(PoolKey calldata key, int24 tickLower, int24 tickUpper) external onlyOwner {
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower % key.tickSpacing != 0 || tickUpper % key.tickSpacing != 0) revert InvalidTickRange();
        PoolId poolId = key.toId();
        poolTickLower[poolId] = tickLower;
        poolTickUpper[poolId] = tickUpper;
        emit TickRangeUpdated(poolId, tickLower, tickUpper);
    }

    /// @notice Set the operator address for a pool.
    function setPoolOperator(PoolKey calldata key, address operator) external onlyOwner {
        poolOperator[key.toId()] = operator;
    }

    /// @notice Enable or disable external deposits for a pool.
    function setExternalDeposits(PoolKey calldata key, bool enabled) external onlyOwner {
        externalDepositsEnabled[key.toId()] = enabled;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: IALFHook OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Indicative quote using hypothetical JIT liquidity.
    /// @dev    Ignores hookData — pricing is fully determined by the stored PricingState.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        return _price(key, zeroForOne, amountSpecified, false, address(0));
    }

    /// @notice Simulate a price-bounded swap against hypothetical JIT liquidity.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata
    ) external view override returns (uint256 amountIn, uint256 amountOut) {
        PoolId poolId = key.toId();

        uint24 feePips;
        uint128 liquidity;
        {
            PricingState memory state = pricingState[poolId];
            if (!state.live) return (0, 0);

            liquidity = _computeJITLiquidity(key);
            if (liquidity == 0) return (0, 0);

            feePips = zeroForOne ? state.bidFeePips : state.askFeePips;
        }

        uint160 effectiveLimit;
        {
            uint160 tickBoundary = zeroForOne
                ? TickMath.getSqrtPriceAtTick(poolTickLower[poolId])
                : TickMath.getSqrtPriceAtTick(poolTickUpper[poolId]);
            effectiveLimit = zeroForOne
                ? (sqrtPriceLimitX96 > tickBoundary ? sqrtPriceLimitX96 : tickBoundary)
                : (sqrtPriceLimitX96 < tickBoundary ? sqrtPriceLimitX96 : tickBoundary);
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        (, amountIn, amountOut,) =
            SwapMath.computeSwapStep(sqrtPriceX96, effectiveLimit, liquidity, amountSpecified, feePips);
    }

    /// @notice Total reserves managed by this hook for the given pool.
    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _getTotalAssets(key);
    }

    /// @notice Assets available for immediate swapping.
    function getEffectiveLiquidity(PoolKey calldata key)
        external
        view
        override
        returns (uint256 token0, uint256 token1)
    {
        return _getTotalAssets(key);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function sharesOf(PoolKey calldata key, address user) external view returns (uint256) {
        return userShares[key.toId()][user];
    }

    function previewRemoveLiquidity(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertSharesToAmounts(key, shares, Rounding.Floor);
    }

    function previewAddLiquidity(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertSharesToAmounts(key, shares, Rounding.Ceil);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        PUBLIC: HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════════════

    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert Unauthorized();
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev JIT entry: read pricing state directly, deploy LP. No hookData processing.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PricingState memory state = pricingState[poolId];

        if (!state.live) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint24 feePips = params.zeroForOne ? state.bidFeePips : state.askFeePips;
        _deployJIT(poolId, key);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev JIT teardown: remove LP, resolve net delta, re-deposit to vaults.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        uint128 liquidity = _activeJITLiquidity[poolId];

        if (liquidity > 0) {
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: poolTickLower[poolId],
                    tickUpper: poolTickUpper[poolId],
                    liquidityDelta: -int256(uint256(liquidity)),
                    salt: LP_SALT
                }),
                ""
            );
            _activeJITLiquidity[poolId] = 0;

            _resolveNetDelta(poolId, key.currency0);
            _resolveNetDelta(poolId, key.currency1);
            _depositAllToVaults(poolId, key);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: JIT LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deploy all managed assets as JIT LP.
    function _deployJIT(PoolId poolId, PoolKey calldata key) internal {
        (uint256 bal0, uint256 bal1) = _getTotalAssets(key);
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 tl = poolTickLower[poolId];
        int24 tu = poolTickUpper[poolId];

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), bal0, bal1
        );
        if (liquidity == 0) return;

        _withdrawAllFromVaults(poolId, key);
        _redeemPoolClaims(poolId, key.currency0);
        _redeemPoolClaims(poolId, key.currency1);

        _poolERC20[poolId][key.currency0] = 0;
        _poolERC20[poolId][key.currency1] = 0;

        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(liquidity)), salt: LP_SALT}),
            ""
        );
        _activeJITLiquidity[poolId] = liquidity;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: DELTA RESOLUTION
    // ═══════════════════════════════════════════════════════════════════════════

    function _redeemPoolClaims(PoolId poolId, Currency currency) internal {
        uint256 claims = _poolClaims[poolId][currency];
        if (claims > 0) {
            poolManager.burn(address(this), currency.toId(), claims);
            poolManager.take(currency, address(this), claims);
            _poolClaims[poolId][currency] = 0;
        }
    }

    function _resolveNetDelta(PoolId poolId, Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            _settle(currency, address(this), uint256(-delta));
        } else if (delta > 0) {
            uint256 amount = uint256(delta);
            poolManager.mint(address(this), currency.toId(), amount);
            _poolClaims[poolId][currency] += amount;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: VAULT OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function _depositToVault(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _poolERC20[poolId][currency] += amount;
            return;
        }
        IERC20Minimal(Currency.unwrap(currency)).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));
        _poolVaultShares[poolId][currency] += shares;
    }

    function _withdrawAllFromVaults(PoolId poolId, PoolKey calldata key) internal {
        _withdrawAllFromVault(poolId, key.currency0);
        _withdrawAllFromVault(poolId, key.currency1);
    }

    function _withdrawAllFromVault(PoolId poolId, Currency currency) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return;
        uint256 shares = _poolVaultShares[poolId][currency];
        if (shares == 0) return;

        uint256 maxRedeemable = vault.maxRedeem(address(this));
        uint256 toRedeem = shares > maxRedeemable ? maxRedeemable : shares;
        if (toRedeem == 0) return;

        vault.redeem(toRedeem, address(this), address(this));
        _poolVaultShares[poolId][currency] -= toRedeem;
    }

    function _depositAllToVaults(PoolId poolId, PoolKey calldata key) internal {
        _depositAllToVault(poolId, key.currency0);
        _depositAllToVault(poolId, key.currency1);
    }

    function _depositAllToVault(PoolId poolId, Currency currency) internal {
        uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _poolERC20[poolId][currency] += bal;
            return;
        }
        IERC20Minimal(Currency.unwrap(currency)).approve(address(vault), bal);
        uint256 shares = vault.deposit(bal, address(this));
        _poolVaultShares[poolId][currency] += shares;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: ASSET TRACKING & PRICING
    // ═══════════════════════════════════════════════════════════════════════════

    function _getTotalAssets(PoolKey memory key) internal view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        amount0 = _getAssetBalance(poolId, key.currency0);
        amount1 = _getAssetBalance(poolId, key.currency1);
    }

    function _getAssetBalance(PoolId poolId, Currency currency) internal view returns (uint256 bal) {
        bal = _poolClaims[poolId][currency] + _poolERC20[poolId][currency];
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) != address(0)) {
            uint256 shares = _poolVaultShares[poolId][currency];
            if (shares > 0) bal += vault.convertToAssets(shares);
        }
    }

    /// @dev Indicative output using hypothetical JIT liquidity.
    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool, address)
        internal
        view
        override
        returns (uint256 outputAmount)
    {
        PoolId poolId = key.toId();
        PricingState memory state = pricingState[poolId];
        if (!state.live) return 0;

        uint128 liquidity = _computeJITLiquidity(key);
        if (liquidity == 0) return 0;

        uint24 feePips = zeroForOne ? state.bidFeePips : state.askFeePips;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 limit = zeroForOne
            ? TickMath.getSqrtPriceAtTick(poolTickLower[poolId])
            : TickMath.getSqrtPriceAtTick(poolTickUpper[poolId]);
        (,, outputAmount,) = SwapMath.computeSwapStep(sqrtPriceX96, limit, liquidity, amountSpecified, feePips);
    }

    function _computeJITLiquidity(PoolKey memory key) internal view returns (uint128) {
        PoolId poolId = key.toId();
        (uint256 bal0, uint256 bal1) = _getTotalAssets(key);
        if (bal0 == 0 && bal1 == 0) return 0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(poolTickLower[poolId]),
            TickMath.getSqrtPriceAtTick(poolTickUpper[poolId]),
            bal0,
            bal1
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: SHARE MATH & AUTH
    // ═══════════════════════════════════════════════════════════════════════════

    function _convertSharesToAmounts(PoolKey memory key, uint256 shares, Rounding rounding)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        uint256 _totalShares = totalShares[poolId];
        if (_totalShares == 0) return (shares, shares);

        (uint256 total0, uint256 total1) = _getTotalAssets(key);
        if (rounding == Rounding.Ceil) {
            amount0 = Math.ceilDiv(shares * total0, _totalShares);
            amount1 = Math.ceilDiv(shares * total1, _totalShares);
        } else {
            amount0 = shares * total0 / _totalShares;
            amount1 = shares * total1 / _totalShares;
        }
    }

    function _ensureERC20Balance(PoolId poolId, Currency currency, uint256 amount) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _poolERC20[poolId][currency] -= amount;
            return;
        }

        uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal >= amount) return;

        uint256 shares = vault.previewWithdraw(amount - bal);
        uint256 poolShares = _poolVaultShares[poolId][currency];
        if (shares > poolShares) shares = poolShares;

        vault.redeem(shares, address(this), address(this));
        _poolVaultShares[poolId][currency] -= shares;
    }

    function _requireDepositAuth(PoolId poolId) internal view {
        if (msg.sender == owner() || msg.sender == poolOperator[poolId]) return;
        if (externalDepositsEnabled[poolId]) return;
        revert ExternalDepositsDisabled();
    }
}
