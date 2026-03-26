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
///         Pricing is via SpreadQuoterBase fee overrides with EIP-712 signed curve updates. Each
///         pool supports a configurable tick range, per-currency ERC4626 vault assignment, and
///         optional external deposits with share-based accounting.
///
///         All asset tracking is pool-scoped: vault shares, ERC-6909 claims, and indicative
///         quotes are isolated per pool, enabling a single hook instance to serve multiple pools
///         without cross-contamination.
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

    /// @dev Per-pool vault share tracking. Each pool's claim on the vault is tracked separately
    ///      so that multi-pool deployments sharing a vault don't cross-contaminate.
    mapping(PoolId => mapping(Currency => uint256)) internal _poolVaultShares;

    /// @dev Per-pool ERC-6909 claim tracking. Claims accumulate in afterSwap (when the PM may
    ///      lack ERC-20 for a take) and are redeemed in the next beforeSwap.
    mapping(PoolId => mapping(Currency => uint256)) internal _poolClaims;

    /// @dev Per-pool ERC-20 balance tracking for pools without a vault configured.
    ///      When a vault is set, assets are tracked via _poolVaultShares instead.
    mapping(PoolId => mapping(Currency => uint256)) internal _poolERC20;

    // ──── Events ────

    event PoolCreated(PoolId indexed poolId, int24 tickLower, int24 tickUpper, address operator);
    event VaultConfigured(PoolId indexed poolId, Currency indexed currency, address vault);
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

    /// @notice Initialize a new pool with this hook and configure all parameters in one call.
    /// @dev    Calls `poolManager.initialize` internally.
    function initializePool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        PricingState calldata pricing,
        int24 tickLower,
        int24 tickUpper,
        address operator,
        bool allowExternalDeposits
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

        tick = poolManager.initialize(key, sqrtPriceX96);
        emit PoolCreated(poolId, tickLower, tickUpper, operator);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: LP DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit token0 and token1 proportional to the pool's current asset ratio, receive shares.
    /// @dev    First deposit: shares mint 1:1 with each token amount. Amounts rounded up (Ceil)
    ///         to prevent share dilution. Deposited tokens go directly to the configured vaults.
    function addLiquidity(PoolKey calldata key, uint256 sharesToMint)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        _requireDepositAuth(poolId);

        (amount0, amount1) = _convertSharesToAmounts(key, sharesToMint, Rounding.Ceil);

        if (amount0 > 0) {
            IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1);
        }

        _depositToVault(poolId, key.currency0, amount0);
        _depositToVault(poolId, key.currency1, amount1);

        totalShares[poolId] += sharesToMint;
        userShares[poolId][msg.sender] += sharesToMint;

        emit LiquidityAdded(poolId, msg.sender, sharesToMint, amount0, amount1);
    }

    /// @notice Burn shares and receive proportional token0 + token1.
    /// @dev    Amounts rounded down (Floor) to prevent over-withdrawal. Tokens are withdrawn
    ///         from vaults if necessary.
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

        if (amount0 > 0) {
            IERC20Minimal(Currency.unwrap(key.currency0)).transfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20Minimal(Currency.unwrap(key.currency1)).transfer(msg.sender, amount1);
        }

        emit LiquidityRemoved(poolId, msg.sender, sharesToBurn, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: OWNER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configure or remove an ERC4626 vault for a (pool, currency) pair.
    /// @dev    If changing vaults and the old vault holds shares, they are redeemed first.
    ///         `address(0)` disables rehypothecation for this asset.
    function setVault(PoolKey calldata key, Currency currency, IERC4626 vault) external onlyOwner {
        PoolId poolId = key.toId();

        IERC4626 oldVault = vaults[poolId][currency];
        if (address(oldVault) != address(0) && address(oldVault) != address(vault)) {
            uint256 oldShares = _poolVaultShares[poolId][currency];
            if (oldShares > 0) {
                oldVault.redeem(oldShares, address(this), address(this));
                _poolVaultShares[poolId][currency] = 0;
            }
        }

        vaults[poolId][currency] = vault;

        if (address(vault) != address(0)) {
            uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
            if (bal > 0) {
                IERC20Minimal(Currency.unwrap(currency)).approve(address(vault), bal);
                uint256 shares = vault.deposit(bal, address(this));
                _poolVaultShares[poolId][currency] += shares;
            }
        }

        emit VaultConfigured(poolId, currency, address(vault));
    }

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
    /// @dev    Overrides SpreadQuoterBase (which simulates against onchain LP) because JIT pools
    ///         have zero liquidity between swaps. Computes the JIT liquidity from vault assets
    ///         and simulates a single swap step.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        (, bool isAttested,) = _resolveHookData(hookData);
        return _price(key, zeroForOne, amountSpecified, isAttested, address(0));
    }

    /// @notice Simulate a price-bounded swap against hypothetical JIT liquidity.
    /// @dev    Uses a single SwapMath step with the caller's price limit clamped to the tick range.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external view override returns (uint256 amountIn, uint256 amountOut) {
        PoolId poolId = key.toId();

        uint24 feePips;
        uint128 liquidity;
        {
            PricingState memory state = pricingState[poolId];
            if (!state.live) return (0, 0);

            liquidity = _computeJITLiquidity(key);
            if (liquidity == 0) return (0, 0);

            (, bool isAttested,) = _resolveHookData(hookData);
            feePips = _effectiveFee(state, zeroForOne, isAttested);
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
    /// @dev    For JIT with instant-withdrawal vaults, effective liquidity equals reserves.
    ///         Differs if a vault has withdrawal delays or caps.
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

    /// @notice Share balance of `user` in the given pool.
    function sharesOf(PoolKey calldata key, address user) external view returns (uint256) {
        return userShares[key.toId()][user];
    }

    /// @notice Preview token amounts returned for burning `shares`.
    function previewRemoveLiquidity(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertSharesToAmounts(key, shares, Rounding.Floor);
    }

    /// @notice Preview token amounts required for minting `shares`.
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

    /// @dev Blocks direct pool initialization — callers must use `initializePool`.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert Unauthorized();
    }

    /// @dev Only the hook itself may add/remove pool liquidity (during JIT cycles).
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

    /// @dev JIT entry: resolve pricing, deploy all managed assets as concentrated LP.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        uint24 feeOverride = _resolvePricing(poolId, key, params.zeroForOne, hookData);
        if (feeOverride == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        _deployJIT(poolId, key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
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

    /// @dev Resolve pricing from hookData. Returns 0 if not live (swap should no-op).
    function _resolvePricing(PoolId poolId, PoolKey calldata, bool zeroForOne, bytes calldata hookData)
        internal
        returns (uint24 feeOverride)
    {
        (bytes memory curveUpdateData, bool isAttested,) = _resolveHookData(hookData);
        if (curveUpdateData.length > 0) {
            _applyCurveUpdate(poolId, curveUpdateData);
        }

        PricingState memory state = pricingState[poolId];
        if (!state.live) return 0;

        uint24 feePips = _effectiveFee(state, zeroForOne, isAttested);
        return feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    /// @dev Deploy all managed assets as JIT LP. Withdraws from vaults (capped at available),
    ///      redeems pool-scoped claims, then adds concentrated LP at the configured tick range.
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

        // Zero out per-pool ERC-20 tracking — tokens are now deployed as LP
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

    /// @dev Redeem this pool's ERC-6909 claims to ERC-20. Claims accumulate when afterSwap
    ///      mints positive deltas (PM may lack ERC-20 at that point).
    function _redeemPoolClaims(PoolId poolId, Currency currency) internal {
        uint256 claims = _poolClaims[poolId][currency];
        if (claims > 0) {
            poolManager.burn(address(this), currency.toId(), claims);
            poolManager.take(currency, address(this), claims);
            _poolClaims[poolId][currency] = 0;
        }
    }

    /// @dev Resolve the hook's net delta for a single currency after the JIT cycle.
    ///      Negative delta: settle from ERC-20.
    ///      Positive delta: mint as ERC-6909 claims (PM may lack ERC-20 since the swapper
    ///      hasn't settled yet). Claims are tracked per-pool and redeemed next beforeSwap.
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

    /// @dev Deposit `amount` into the pool's vault (or track as ERC-20 if no vault).
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

    /// @dev Withdraw all redeemable vault shares for both currencies. Caps at vault.maxRedeem
    ///      to handle vaults with high utilization that can't honor full withdrawal.
    function _withdrawAllFromVaults(PoolId poolId, PoolKey calldata key) internal {
        _withdrawAllFromVault(poolId, key.currency0);
        _withdrawAllFromVault(poolId, key.currency1);
    }

    /// @dev Withdraw all redeemable shares for a single (pool, currency).
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

    /// @dev Deposit all ERC-20 balances for both currencies into their vaults.
    function _depositAllToVaults(PoolId poolId, PoolKey calldata key) internal {
        _depositAllToVault(poolId, key.currency0);
        _depositAllToVault(poolId, key.currency1);
    }

    /// @dev Deposit the hook's ERC-20 balance of a currency into its vault, or track per-pool.
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
    //                        INTERNAL: ASSET TRACKING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Total managed assets for both currencies of a pool.
    function _getTotalAssets(PoolKey memory key) internal view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        amount0 = _getAssetBalance(poolId, key.currency0);
        amount1 = _getAssetBalance(poolId, key.currency1);
    }

    /// @dev Total managed balance for a single (pool, currency) pair.
    ///      Sums per-pool vault assets + per-pool ERC-6909 claims + per-pool ERC-20 (no-vault case).
    function _getAssetBalance(PoolId poolId, Currency currency) internal view returns (uint256 bal) {
        bal = _poolClaims[poolId][currency] + _poolERC20[poolId][currency];
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) != address(0)) {
            uint256 shares = _poolVaultShares[poolId][currency];
            if (shares > 0) {
                bal += vault.convertToAssets(shares);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: PRICING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Indicative output using hypothetical JIT liquidity and a single SwapMath step.
    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool isAttested, address)
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

        uint24 feePips = _effectiveFee(state, zeroForOne, isAttested);
        return _simulateSwapStep(poolId, zeroForOne, amountSpecified, liquidity, feePips);
    }

    /// @dev Compute the JIT liquidity that would be deployed given current assets and price.
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

    /// @dev Single-step swap simulation against hypothetical JIT liquidity.
    function _simulateSwapStep(PoolId poolId, bool zeroForOne, int256 amountSpecified, uint128 liquidity, uint24 feePips)
        internal
        view
        returns (uint256 amountOut)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 limit = zeroForOne
            ? TickMath.getSqrtPriceAtTick(poolTickLower[poolId])
            : TickMath.getSqrtPriceAtTick(poolTickUpper[poolId]);
        (,, amountOut,) = SwapMath.computeSwapStep(sqrtPriceX96, limit, liquidity, amountSpecified, feePips);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: SHARE MATH & AUTH
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Convert share count to token amounts based on the pool's current asset ratio.
    ///      First deposit (totalShares == 0): 1 share = 1 unit of each token.
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

    /// @dev Ensure the hook holds enough ERC-20 for a withdrawal. Pulls from vault if needed.
    ///      Debits _poolERC20 for no-vault pools.
    function _ensureERC20Balance(PoolId poolId, Currency currency, uint256 amount) internal {
        // For no-vault pools, debit the per-pool tracker
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _poolERC20[poolId][currency] -= amount;
            return;
        }

        // For vault pools, withdraw from vault if needed
        uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal >= amount) return;

        uint256 shares = vault.previewWithdraw(amount - bal);
        uint256 poolShares = _poolVaultShares[poolId][currency];
        if (shares > poolShares) shares = poolShares;

        vault.redeem(shares, address(this), address(this));
        _poolVaultShares[poolId][currency] -= shares;
    }

    /// @dev Revert if caller is not authorized to deposit.
    function _requireDepositAuth(PoolId poolId) internal view {
        if (msg.sender == owner() || msg.sender == poolOperator[poolId]) return;
        if (externalDepositsEnabled[poolId]) return;
        revert ExternalDepositsDisabled();
    }
}
