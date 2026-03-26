// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
import {SpreadQuoterBase} from "./base/SpreadQuoterBase.sol";
import {PoolVault} from "./base/PoolVault.sol";

/// @title SmartPoolHook
/// @notice JIT spread quoter with ERC4626 vault rehypothecation.
///
///         beforeSwap  → withdraw from vaults, deploy concentrated LP
///         [pool executes swap against the LP with fee override]
///         afterSwap   → remove LP, re-deposit to vaults
///
///         Pricing via SpreadQuoterBase fee overrides. Vaults set at pool creation.
///         Share accounting and vault interaction inherited from PoolVault.
contract SmartPoolHook is SpreadQuoterBase, PoolVault, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    bytes32 public constant LP_SALT = bytes32(uint256(0x534D5254)); // "SMRT"

    // ──── Types ────

    /// @notice Configuration for initializing a new pool.
    struct PoolConfig {
        uint160 sqrtPriceX96;
        PricingState pricing;
        int24 tickLower;
        int24 tickUpper;
        address operator;
        bool allowExternalDeposits;
        IERC4626 vault0;
        IERC4626 vault1;
    }

    // ──── Per-Pool State ────

    mapping(PoolId => int24) public poolTickLower;
    mapping(PoolId => int24) public poolTickUpper;
    mapping(PoolId => bool) public externalDepositsEnabled;
    mapping(PoolId => address) public poolOperator;
    mapping(PoolId => PoolKey) internal _poolKeys;
    mapping(PoolId => uint128) internal _activeJITLiquidity;

    // ──── Events ────

    event PoolCreated(PoolId indexed poolId, int24 tickLower, int24 tickUpper, address operator);
    event TickRangeUpdated(PoolId indexed poolId, int24 tickLower, int24 tickUpper);

    // ──── Errors ────

    error LiquidityNotAllowed();
    error ExternalDepositsDisabled();
    error InvalidHookAddress();
    error MustUseDynamicFee();
    error Unauthorized();

    // ──── Constructor ────

    constructor(
        IPoolManager _pm,
        uint32 maxGas_,
        address owner_
    ) SpreadQuoterBase(_pm, maxGas_, owner_, "SmartPoolHook") {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool with vaults, pricing, and operator in one call.
    /// @dev    Vaults are permanent — set at creation and cannot be changed.
    /// @param key    The PoolKey (must reference this hook and use DYNAMIC_FEE_FLAG).
    /// @param config Pool configuration (pricing, tick range, vaults, operator).
    /// @return tick  The initial tick assigned by the PoolManager.
    function initializePool(PoolKey calldata key, PoolConfig calldata config)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert MustUseDynamicFee();
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (config.tickLower >= config.tickUpper) revert InvalidTickRange();
        if (config.tickLower % key.tickSpacing != 0 || config.tickUpper % key.tickSpacing != 0) {
            revert InvalidTickRange();
        }

        PoolId poolId = key.toId();
        _poolKeys[poolId] = key;
        pricingState[poolId] = config.pricing;
        poolTickLower[poolId] = config.tickLower;
        poolTickUpper[poolId] = config.tickUpper;
        poolOperator[poolId] = config.operator;
        externalDepositsEnabled[poolId] = config.allowExternalDeposits;
        vaults[poolId][key.currency0] = config.vault0;
        vaults[poolId][key.currency1] = config.vault1;

        tick = poolManager.initialize(key, config.sqrtPriceX96);
        emit PoolCreated(poolId, config.tickLower, config.tickUpper, config.operator);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: LP DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    function addLiquidity(PoolKey calldata key, uint256 sharesToMint)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _requireDepositAuth(key.toId());
        return _deposit(key, msg.sender, msg.sender, sharesToMint);
    }

    function removeLiquidity(PoolKey calldata key, uint256 sharesToBurn)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        return _withdraw(key, msg.sender, msg.sender, sharesToBurn);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: OWNER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    function setTickRange(PoolKey calldata key, int24 tickLower, int24 tickUpper) external onlyOwner {
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower % key.tickSpacing != 0 || tickUpper % key.tickSpacing != 0) revert InvalidTickRange();
        PoolId poolId = key.toId();
        poolTickLower[poolId] = tickLower;
        poolTickUpper[poolId] = tickUpper;
        emit TickRangeUpdated(poolId, tickLower, tickUpper);
    }

    function setPoolOperator(PoolKey calldata key, address operator) external onlyOwner {
        poolOperator[key.toId()] = operator;
    }

    function setExternalDeposits(PoolKey calldata key, bool enabled) external onlyOwner {
        externalDepositsEnabled[key.toId()] = enabled;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: IALFHook OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Indicative quote against hypothetical JIT liquidity. Ignores hookData.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        return _price(key, zeroForOne, amountSpecified, false, address(0));
    }

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
            uint160 boundary = zeroForOne
                ? TickMath.getSqrtPriceAtTick(poolTickLower[poolId])
                : TickMath.getSqrtPriceAtTick(poolTickUpper[poolId]);
            effectiveLimit = zeroForOne
                ? (sqrtPriceLimitX96 > boundary ? sqrtPriceLimitX96 : boundary)
                : (sqrtPriceLimitX96 < boundary ? sqrtPriceLimitX96 : boundary);
        }
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        (, amountIn, amountOut,) =
            SwapMath.computeSwapStep(sqrtPriceX96, effectiveLimit, liquidity, amountSpecified, feePips);
    }

    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _totalAssets(key);
    }

    function getEffectiveLiquidity(PoolKey calldata key)
        external
        view
        override
        returns (uint256 token0, uint256 token1)
    {
        return _totalAssets(key);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    function sharesOf(PoolKey calldata key, address user) external view returns (uint256) {
        return userShares[key.toId()][user];
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
            _resolveNetDelta(poolId, key);
            _depositAllToVaults(poolId, key);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: JIT LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    function _deployJIT(PoolId poolId, PoolKey calldata key) internal {
        (uint256 bal0, uint256 bal1) = _totalAssets(key);
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
        _clearERC20Tracking(poolId, key.currency0);
        _clearERC20Tracking(poolId, key.currency1);

        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(liquidity)), salt: LP_SALT}),
            ""
        );
        _activeJITLiquidity[poolId] = liquidity;
    }

    /// @dev Resolve net delta for both currencies after JIT remove.
    function _resolveNetDelta(PoolId poolId, PoolKey calldata key) internal {
        _resolveNetDeltaCurrency(poolId, key.currency0);
        _resolveNetDeltaCurrency(poolId, key.currency1);
    }

    function _resolveNetDeltaCurrency(PoolId poolId, Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            _settle(currency, address(this), uint256(-delta));
        } else if (delta > 0) {
            uint256 amount = uint256(delta);
            poolManager.mint(address(this), currency.toId(), amount);
            _recordClaims(poolId, currency, amount);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: PRICING
    // ═══════════════════════════════════════════════════════════════════════════

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
        (uint256 bal0, uint256 bal1) = _totalAssets(key);
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
    //                        INTERNAL: AUTH & POOL MANAGER
    // ═══════════════════════════════════════════════════════════════════════════

    function _requireDepositAuth(PoolId poolId) internal view {
        if (msg.sender == owner() || msg.sender == poolOperator[poolId]) return;
        if (externalDepositsEnabled[poolId]) return;
        revert ExternalDepositsDisabled();
    }

    /// @dev PoolVault needs access to the PoolManager for claim operations.
    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }
}
