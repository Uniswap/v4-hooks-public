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
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SpreadQuoterBase} from "./base/SpreadQuoterBase.sol";
import {PoolVault} from "./base/PoolVault.sol";

/// @title SmartPoolHook
/// @notice JIT spread quoter with ERC4626 vault rehypothecation and multi-range liquidity
///         distribution.
///
///         Assets are deployed across multiple tick ranges ("buckets") during each JIT cycle,
///         with owner-configured weights that control capital concentration. Token allocation
///         across buckets uses `getLiquidityForAmounts` at the current price so that no capital
///         sits idle — even when the price has drifted and ranges are asymmetric.
///
///         Example: 75% at [-10,10], 15% at [-30,30], 10% at [-60,60] concentrates most
///         liquidity around the peg while maintaining depth for larger price moves.
contract SmartPoolHook is SpreadQuoterBase, PoolVault, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    bytes32 public constant LP_SALT = bytes32(uint256(0x534D5254)); // "SMRT"

    /// @dev Maximum number of buckets per pool. Bounds gas cost of JIT cycle.
    uint8 public constant MAX_BUCKETS = 8;

    // ──── Types ────

    /// @notice A tick range with a weight for liquidity distribution.
    /// @dev    Weights are in basis points and must sum to 10_000 across all buckets.
    struct LiquidityBucket {
        int24 tickLower;
        int24 tickUpper;
        uint16 weightBps;
    }

    /// @notice Configuration for initializing a new pool.
    struct PoolConfig {
        uint160 sqrtPriceX96;
        PricingState pricing;
        LiquidityBucket[] distribution;
        bool allowExternalDeposits;
        IERC4626 vault0;
        IERC4626 vault1;
    }

    // ──── Per-Pool State ────

    /// @dev Packed scalar state (single slot): externalDepositsEnabled(1) + numBuckets(1) = 2 bytes
    mapping(PoolId => bool) public externalDepositsEnabled;
    mapping(PoolId => PoolKey) internal _poolKeys;

    /// @dev Liquidity distribution per pool. Set at initialization, updatable by owner.
    mapping(PoolId => LiquidityBucket[]) internal _distribution;

    /// @dev Active JIT liquidity per bucket (parallel array with _distribution). Zero between swaps.
    mapping(PoolId => uint128[]) internal _activeLiquidity;

    // ──── Events ────

    event PoolCreated(PoolId indexed poolId);
    event DistributionUpdated(PoolId indexed poolId);

    // ──── Errors ────

    error LiquidityNotAllowed();
    error InvalidHookAddress();
    error MustUseDynamicFee();
    error Unauthorized();
    error InvalidDistribution();

    // ──── Constructor ────

    constructor(
        IPoolManager _pm,
        uint32 maxGas_,
        address owner_
    ) SpreadQuoterBase(_pm, maxGas_, owner_, "SmartPoolHook") {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool with vaults, pricing, and liquidity distribution.
    function initializePool(PoolKey calldata key, PoolConfig calldata config)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert MustUseDynamicFee();
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();

        PoolId poolId = key.toId();
        _poolKeys[poolId] = key;
        pricingState[poolId] = config.pricing;
        externalDepositsEnabled[poolId] = config.allowExternalDeposits;
        vaults[poolId][key.currency0] = config.vault0;
        vaults[poolId][key.currency1] = config.vault1;

        _setDistribution(poolId, config.distribution, key.tickSpacing);

        tick = poolManager.initialize(key, config.sqrtPriceX96);
        emit PoolCreated(poolId);
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

    /// @notice Replace the liquidity distribution for a pool.
    /// @dev    Weights must sum to 10_000. Ticks must be aligned to tickSpacing.
    ///         Can only be called between swaps (no active JIT positions).
    function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets) external onlyOwner {
        _setDistribution(key.toId(), buckets, key.tickSpacing);
        emit DistributionUpdated(key.toId());
    }

    function setExternalDeposits(PoolKey calldata key, bool enabled) external onlyOwner {
        externalDepositsEnabled[key.toId()] = enabled;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: IALFHook OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        return _price(key, zeroForOne, amountSpecified, false, address(0));
    }

    function swapToPrice(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        view
        override
        returns (uint256 amountIn, uint256 amountOut)
    {
        return _swapToPrice(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _totalAssets(key);
    }

    function getEffectiveLiquidity(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _totalAssets(key);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    function sharesOf(PoolKey calldata key, address user) external view returns (uint256) {
        return userShares[key.toId()][user];
    }

    function getDistribution(PoolId poolId) external view returns (LiquidityBucket[] memory) {
        return _distribution[poolId];
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
        internal view override returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal view override returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
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
        internal override returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        _removeJIT(poolId, key);
        _resolveNetDelta(poolId, key);
        _depositAllToVaults(poolId, key);
        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: JIT LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deploy JIT liquidity across all distribution buckets.
    ///
    ///      Three-phase strategy:
    ///        1. Compute weighted liquidity per bucket and exact token amounts needed
    ///        2. Withdraw only the required amounts from vaults (rest keeps earning yield)
    ///        3. Deploy each bucket's position
    ///
    ///      Allocation: each bucket's max liquidity from the full balance is computed via
    ///      getLiquidityForAmounts, then scaled by weight. SqrtPriceMath computes the exact
    ///      token amounts per bucket, which are summed for targeted vault withdrawal.
    function _deployJIT(PoolId poolId, PoolKey calldata key) internal {
        (uint256 bal0, uint256 bal1) = _totalAssets(key);
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        LiquidityBucket[] storage dist = _distribution[poolId];
        uint256 n = dist.length;
        if (n == 0) return;

        // Phase 1: compute weighted liquidity per bucket and total token needs.
        uint128[] memory liqs = new uint128[](n);
        uint256 totalNeed0;
        uint256 totalNeed1;

        for (uint256 i; i < n; i++) {
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(dist[i].tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(dist[i].tickUpper);

            uint128 maxLiq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtLower, sqrtUpper, bal0, bal1
            );
            uint128 liq = uint128(uint256(maxLiq) * dist[i].weightBps / 10_000);
            liqs[i] = liq;

            if (liq == 0) continue;

            // Compute exact tokens this bucket needs using v4-core's SqrtPriceMath.
            // getAmount0Delta covers the above-price portion, getAmount1Delta the below-price.
            if (sqrtPriceX96 < sqrtUpper) {
                uint160 effectiveUpper = sqrtPriceX96 < sqrtLower ? sqrtLower : sqrtPriceX96;
                totalNeed0 += SqrtPriceMath.getAmount0Delta(effectiveUpper, sqrtUpper, liq, true);
            }
            if (sqrtPriceX96 > sqrtLower) {
                uint160 effectiveLower = sqrtPriceX96 > sqrtUpper ? sqrtUpper : sqrtPriceX96;
                totalNeed1 += SqrtPriceMath.getAmount1Delta(sqrtLower, effectiveLower, liq, true);
            }
        }

        if (totalNeed0 == 0 && totalNeed1 == 0) return;

        // Phase 2: liquidate claims to ERC-20 (cheaper than vault), then pull shortfall from vault.
        _redeemPoolClaims(poolId, key.currency0);
        _redeemPoolClaims(poolId, key.currency1);

        uint256 onHand0 = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 onHand1 = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));
        if (totalNeed0 > onHand0) _withdrawFromVault(poolId, key.currency0, totalNeed0 - onHand0);
        if (totalNeed1 > onHand1) _withdrawFromVault(poolId, key.currency1, totalNeed1 - onHand1);

        // Phase 3: deploy each bucket.
        uint128[] storage active = _activeLiquidity[poolId];
        for (uint256 i; i < n; i++) {
            if (liqs[i] == 0) continue;
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: dist[i].tickLower,
                    tickUpper: dist[i].tickUpper,
                    liquidityDelta: int256(uint256(liqs[i])),
                    salt: LP_SALT
                }),
                ""
            );
            active[i] = liqs[i];
        }
    }

    /// @dev Remove all active JIT positions.
    function _removeJIT(PoolId poolId, PoolKey calldata key) internal {
        LiquidityBucket[] storage dist = _distribution[poolId];
        uint128[] storage active = _activeLiquidity[poolId];
        uint256 n = dist.length;

        for (uint256 i; i < n; i++) {
            uint128 liq = active[i];
            if (liq == 0) continue;

            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: dist[i].tickLower,
                    tickUpper: dist[i].tickUpper,
                    liquidityDelta: -int256(uint256(liq)),
                    salt: LP_SALT
                }),
                ""
            );
            active[i] = 0;
        }
    }

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
    //                        INTERNAL: DISTRIBUTION MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Validate and store a liquidity distribution.
    function _setDistribution(PoolId poolId, LiquidityBucket[] calldata buckets, int24 tickSpacing) internal {
        uint256 n = buckets.length;
        if (n == 0 || n > MAX_BUCKETS) revert InvalidDistribution();

        uint256 totalWeight;
        for (uint256 i; i < n; i++) {
            if (buckets[i].tickLower >= buckets[i].tickUpper) revert InvalidTickRange();
            if (buckets[i].tickLower % tickSpacing != 0 || buckets[i].tickUpper % tickSpacing != 0) {
                revert InvalidTickRange();
            }
            if (buckets[i].weightBps == 0) revert InvalidDistribution();
            totalWeight += buckets[i].weightBps;
        }
        if (totalWeight != 10_000) revert InvalidDistribution();

        // Replace storage arrays
        delete _distribution[poolId];
        delete _activeLiquidity[poolId];

        for (uint256 i; i < n; i++) {
            _distribution[poolId].push(buckets[i]);
            _activeLiquidity[poolId].push(0);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: PRICING
    // ═══════════════════════════════════════════════════════════════════════════

    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool, address)
        internal view override returns (uint256 outputAmount)
    {
        (, outputAmount,) = _simulateSwap(key, zeroForOne, amountSpecified);
    }

    function _swapToPrice(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal view returns (uint256 amountIn, uint256 amountOut)
    {
        (uint24 feePips, uint128 totalLiq, int24 outerLower, int24 outerUpper) = _swapParams(key, zeroForOne);
        if (totalLiq == 0) return (0, 0);

        uint160 boundary = zeroForOne
            ? TickMath.getSqrtPriceAtTick(outerLower)
            : TickMath.getSqrtPriceAtTick(outerUpper);
        uint160 effectiveLimit = zeroForOne
            ? (sqrtPriceLimitX96 > boundary ? sqrtPriceLimitX96 : boundary)
            : (sqrtPriceLimitX96 < boundary ? sqrtPriceLimitX96 : boundary);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        (, amountIn, amountOut,) = SwapMath.computeSwapStep(sqrtPriceX96, effectiveLimit, totalLiq, amountSpecified, feePips);
    }

    /// @dev Shared simulation logic for _price and _swapToPrice.
    function _simulateSwap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
        internal view returns (uint24 feePips, uint256 outputAmount, uint160 sqrtPriceAfter)
    {
        uint128 totalLiq;
        int24 outerLower;
        int24 outerUpper;
        (feePips, totalLiq, outerLower, outerUpper) = _swapParams(key, zeroForOne);
        if (totalLiq == 0) return (feePips, 0, 0);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint160 limit = zeroForOne
            ? TickMath.getSqrtPriceAtTick(outerLower)
            : TickMath.getSqrtPriceAtTick(outerUpper);
        (sqrtPriceAfter,, outputAmount,) = SwapMath.computeSwapStep(sqrtPriceX96, limit, totalLiq, amountSpecified, feePips);
    }

    /// @dev Compute fee and aggregate liquidity for simulation.
    function _swapParams(PoolKey calldata key, bool zeroForOne)
        internal view returns (uint24 feePips, uint128 totalLiq, int24 outerLower, int24 outerUpper)
    {
        PricingState memory state = pricingState[key.toId()];
        if (!state.live) return (0, 0, 0, 0);
        feePips = zeroForOne ? state.bidFeePips : state.askFeePips;
        (totalLiq, outerLower, outerUpper) = _computeAggregateJITLiquidity(key);
    }

    /// @dev Compute aggregate JIT liquidity and outermost boundaries. Mirrors _deployJIT but view-only.
    function _computeAggregateJITLiquidity(PoolKey memory key)
        internal view returns (uint128 totalLiq, int24 outerLower, int24 outerUpper)
    {
        PoolId poolId = key.toId();
        (uint256 bal0, uint256 bal1) = _totalAssets(key);
        if (bal0 == 0 && bal1 == 0) return (0, 0, 0);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        LiquidityBucket[] storage dist = _distribution[poolId];
        uint256 n = dist.length;
        if (n == 0) return (0, 0, 0);

        outerLower = type(int24).max;
        outerUpper = type(int24).min;

        for (uint256 i; i < n; i++) {
            if (dist[i].tickLower < outerLower) outerLower = dist[i].tickLower;
            if (dist[i].tickUpper > outerUpper) outerUpper = dist[i].tickUpper;

            uint128 maxLiq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(dist[i].tickLower),
                TickMath.getSqrtPriceAtTick(dist[i].tickUpper),
                bal0,
                bal1
            );
            totalLiq += uint128(uint256(maxLiq) * dist[i].weightBps / 10_000);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: AUTH & POOL MANAGER
    // ═══════════════════════════════════════════════════════════════════════════

    function _requireDepositAuth(PoolId poolId) internal view {
        if (msg.sender == owner()) return;
        if (externalDepositsEnabled[poolId]) return;
        revert Unauthorized();
    }

    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }
}
