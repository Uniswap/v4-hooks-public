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
///
///         ## JIT Lifecycle
///
///           beforeSwap:
///             1. Compute per-bucket liquidity from current assets and weights
///             2. Compute exact token amounts needed via SqrtPriceMath
///             3. Redeem claims, withdraw only the shortfall from vaults
///             4. Deploy each bucket as a concentrated LP position
///
///           [pool executes swap against the deployed LP with fee override]
///
///           afterSwap:
///             1. Remove all bucket positions
///             2. Settle net deltas (negative → ERC-20 to PM, positive → mint claims)
///             3. Re-deposit remaining ERC-20 to vaults
///
///         ## Pricing
///
///         Bid/ask spreads are set via SpreadQuoterBase's PricingState and applied as a v4
///         dynamic fee override. The owner updates spreads through `updatePricingState`.
///
///         ## Share Accounting
///
///         Inherited from PoolVault. LPs hold proportional shares of the pool's total assets
///         (vault shares + claims + ERC-20). The multi-range distribution is the pool's strategy,
///         transparent to depositors.
contract SmartPoolHook is SpreadQuoterBase, PoolVault, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice Salt for the hook's LP positions in the PoolManager, distinguishing them
    ///         from positions created by other hooks or LPs on the same pool.
    bytes32 public constant LP_SALT = bytes32(uint256(0x534D5254)); // "SMRT"

    /// @notice Maximum number of buckets per pool. Bounds gas cost of the JIT cycle:
    ///         each bucket requires one modifyLiquidity call to deploy and one to remove,
    ///         so gas scales linearly with bucket count.
    uint8 public constant MAX_BUCKETS = 8;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A tick range with a weight for liquidity distribution.
    /// @param tickLower Lower tick boundary (must be aligned to pool's tickSpacing).
    /// @param tickUpper Upper tick boundary (must be aligned to pool's tickSpacing).
    /// @param weightBps Fraction of total capital allocated to this range, in basis points.
    ///                  All weights across a pool's distribution must sum to 10_000.
    struct LiquidityBucket {
        int24 tickLower;
        int24 tickUpper;
        uint16 weightBps;
    }

    /// @notice Configuration for initializing a new pool. Passed to `initializePool`.
    /// @param sqrtPriceX96         Initial sqrt price (Q64.96) for the v4 pool.
    /// @param pricing              Initial bid/ask spread configuration.
    /// @param distribution         Liquidity distribution buckets (weights must sum to 10_000).
    /// @param allowExternalDeposits Whether non-owner addresses may call `addLiquidity`.
    /// @param vault0               ERC4626 vault for currency0 (address(0) to hold as ERC-20).
    /// @param vault1               ERC4626 vault for currency1 (address(0) to hold as ERC-20).
    struct PoolConfig {
        uint160 sqrtPriceX96;
        PricingState pricing;
        LiquidityBucket[] distribution;
        bool allowExternalDeposits;
        IERC4626 vault0;
        IERC4626 vault1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Whether non-owner addresses may deposit into a pool.
    mapping(PoolId => bool) public externalDepositsEnabled;

    /// @dev Stored pool keys for multi-pool support.
    mapping(PoolId => PoolKey) internal _poolKeys;

    /// @dev Liquidity distribution per pool. Each entry defines a tick range and its weight.
    ///      Set at initialization via `initializePool`, updatable via `setDistribution`.
    mapping(PoolId => LiquidityBucket[]) internal _distribution;

    /// @dev Active JIT liquidity per bucket. Parallel array with `_distribution` — entry `i`
    ///      holds the liquidity deployed at `_distribution[poolId][i]` during the current swap.
    ///      Zero between swaps.
    mapping(PoolId => uint128[]) internal _activeLiquidity;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new pool is initialized via `initializePool`.
    event PoolCreated(PoolId indexed poolId);

    /// @notice Emitted when the liquidity distribution is replaced via `setDistribution`.
    event DistributionUpdated(PoolId indexed poolId);

    // ═══════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev External address attempted to add or remove v4 pool liquidity directly.
    ///      Only the hook itself may modify LP positions (during JIT cycles).
    error LiquidityNotAllowed();

    /// @dev The PoolKey's hooks address does not match this contract.
    error InvalidHookAddress();

    /// @dev The PoolKey's fee must use DYNAMIC_FEE_FLAG for fee override pricing.
    error MustUseDynamicFee();

    /// @dev Caller is not authorized (not owner, or external deposits disabled).
    error Unauthorized();

    /// @dev Distribution is invalid: empty, exceeds MAX_BUCKETS, weights don't sum to 10_000,
    ///      or a bucket has zero weight.
    error InvalidDistribution();

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _pm     The Uniswap v4 PoolManager.
    /// @param maxGas_ Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_  Initial contract owner (Ownable2Step).
    constructor(
        IPoolManager _pm,
        uint32 maxGas_,
        address owner_
    ) SpreadQuoterBase(_pm, maxGas_, owner_, "SmartPoolHook") {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool with vaults, pricing, and liquidity distribution.
    /// @dev    Calls `poolManager.initialize` internally. Vaults are permanent — set at creation
    ///         and cannot be changed. The distribution can be updated later via `setDistribution`.
    /// @param key    The PoolKey (must reference this hook and use DYNAMIC_FEE_FLAG).
    /// @param config Pool configuration including pricing, distribution, vaults, and permissions.
    /// @return tick  The initial tick assigned by the PoolManager.
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

    /// @notice Deposit token0 and token1 proportional to the pool's current asset ratio.
    /// @dev    Requires owner or external deposits enabled. Uses `nonReentrant` to prevent
    ///         reentrancy during vault interactions.
    /// @param key          The pool to deposit into.
    /// @param sharesToMint Number of shares to mint. Use `previewDeposit` to see required amounts.
    /// @return amount0     Actual currency0 transferred from the caller.
    /// @return amount1     Actual currency1 transferred from the caller.
    function addLiquidity(PoolKey calldata key, uint256 sharesToMint)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _requireDepositAuth(key.toId());
        return _deposit(key, msg.sender, msg.sender, sharesToMint);
    }

    /// @notice Burn shares and receive proportional token0 + token1.
    /// @dev    Amounts are rounded down to prevent over-withdrawal. Tokens are withdrawn
    ///         from vaults if the hook's ERC-20 balance is insufficient.
    /// @param key          The pool to withdraw from.
    /// @param sharesToBurn Number of shares to burn. Use `previewWithdraw` to see return amounts.
    /// @return amount0     Actual currency0 transferred to the caller.
    /// @return amount1     Actual currency1 transferred to the caller.
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
    ///         Buckets can be asymmetric, overlapping, or non-contiguous.
    ///         Safe to call at any time — takes effect on the next swap's JIT cycle.
    /// @param key     The pool to update.
    /// @param buckets The new distribution (1 to MAX_BUCKETS entries).
    function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets) external onlyOwner {
        _setDistribution(key.toId(), buckets, key.tickSpacing);
        emit DistributionUpdated(key.toId());
    }

    /// @notice Enable or disable external (non-owner) deposits for a pool.
    /// @param key     The pool to update.
    /// @param enabled True to allow any address to call `addLiquidity`.
    function setExternalDeposits(PoolKey calldata key, bool enabled) external onlyOwner {
        externalDepositsEnabled[key.toId()] = enabled;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: IALFHook OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Indicative quote against hypothetical multi-range JIT liquidity.
    /// @dev    Aggregates liquidity across all distribution buckets and simulates a single
    ///         SwapMath step. This is an approximation — the actual swap may cross tick
    ///         boundaries between bucket ranges, producing slightly different results.
    ///         Ignores hookData (pricing is fully determined by stored PricingState).
    /// @param key              The pool to quote for.
    /// @param zeroForOne       Swap direction (true = token0 → token1).
    /// @param amountSpecified  Swap amount (negative = exact input, positive = exact output).
    /// @return outputAmount    For exact input: estimated output. For exact output: required input.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        return _price(key, zeroForOne, amountSpecified, false, address(0));
    }

    /// @notice Simulate a price-bounded swap against hypothetical JIT liquidity.
    /// @dev    The caller's sqrtPriceLimitX96 is clamped to the outermost bucket boundary.
    /// @param key                The pool to simulate.
    /// @param zeroForOne         Swap direction.
    /// @param amountSpecified    Swap amount (negative = exact input).
    /// @param sqrtPriceLimitX96  Target price (Q64.96). Swap stops when reached.
    /// @return amountIn          Total input consumed (including fees).
    /// @return amountOut         Total output received.
    function swapToPrice(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        view
        override
        returns (uint256 amountIn, uint256 amountOut)
    {
        return _swapToPrice(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    /// @notice Total reserves managed by this hook for the given pool.
    /// @dev    Includes ERC-20, ERC-6909 claims, and ERC4626 vault balances.
    /// @param key    The pool to query.
    /// @return token0 Total currency0 under management.
    /// @return token1 Total currency1 under management.
    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _totalAssets(key);
    }

    /// @notice Assets available for immediate swapping.
    /// @dev    For JIT hooks, effective liquidity equals reserves since all assets are
    ///         deployable. Would differ for vaults with withdrawal delays or caps.
    /// @param key    The pool to query.
    /// @return token0 Immediately deployable currency0.
    /// @return token1 Immediately deployable currency1.
    function getEffectiveLiquidity(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _totalAssets(key);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the share balance of `user` for the given pool.
    /// @param key  The pool to query.
    /// @param user The address to check.
    /// @return     The number of shares held by `user`.
    function sharesOf(PoolKey calldata key, address user) external view returns (uint256) {
        return userShares[key.toId()][user];
    }

    /// @notice Returns the current liquidity distribution for a pool.
    /// @param poolId The pool to query.
    /// @return       Array of liquidity buckets with their tick ranges and weights.
    function getDistribution(PoolId poolId) external view returns (LiquidityBucket[] memory) {
        return _distribution[poolId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        PUBLIC: HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Required v4 hook flags:
    ///      - beforeInitialize: block direct init (force initializePool)
    ///      - afterInitialize: inherited from SpreadQuoterBase (active tick setup)
    ///      - beforeAddLiquidity / beforeRemoveLiquidity: restrict to hook-only LP
    ///      - beforeSwap: JIT deployment + fee override
    ///      - afterSwap: JIT teardown + delta resolution
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

    /// @dev Blocks direct pool initialization. Callers must use `initializePool` which
    ///      validates parameters and configures the distribution before calling PM.initialize.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert Unauthorized();
    }

    /// @dev Only the hook itself may add pool liquidity (during JIT deployment in _beforeSwap).
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal view override returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Only the hook itself may remove pool liquidity (during JIT teardown in _afterSwap).
    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal view override returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev JIT entry point. Reads the stored PricingState for the directional fee, deploys
    ///      multi-range JIT liquidity, and returns the fee override. Returns zero delta and
    ///      no fee if the pool is not live (swap executes against zero liquidity → no output).
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

    /// @dev JIT teardown. Removes all bucket positions, resolves the hook's net delta for both
    ///      currencies, and re-deposits remaining ERC-20 to vaults.
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
    ///        1. **Compute allocations**: for each bucket, compute its weighted liquidity
    ///           from the full balance via `getLiquidityForAmounts`, then use `SqrtPriceMath`
    ///           to determine the exact token0 and token1 needed for deployment.
    ///        2. **Targeted withdrawal**: redeem per-pool ERC-6909 claims first (cheaper
    ///           than vault interaction), then withdraw only the shortfall from vaults.
    ///           Unneeded capital stays in the vault earning yield during the swap window.
    ///        3. **Deploy**: add each bucket as a concentrated LP position.
    ///
    /// @param poolId The pool to deploy for.
    /// @param key    The pool key (for currency references and modifyLiquidity calls).
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

            // Max liquidity this bucket could support from ALL pool assets.
            // Scaling by weight gives the target liquidity for this bucket.
            uint128 maxLiq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtLower, sqrtUpper, bal0, bal1
            );
            uint128 liq = uint128(uint256(maxLiq) * dist[i].weightBps / 10_000);
            liqs[i] = liq;

            if (liq == 0) continue;

            // Exact token amounts this bucket will consume when deployed.
            // Above current price → needs token0. Below current price → needs token1.
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

        // Phase 3: deploy each bucket as a concentrated LP position.
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

    /// @dev Remove all active JIT positions deployed in `_deployJIT`. Iterates the distribution
    ///      and removes each bucket that has non-zero active liquidity. After removal, the hook's
    ///      cumulative delta reflects the net position from the deploy-swap-remove cycle.
    /// @param poolId The pool to remove JIT positions from.
    /// @param key    The pool key (for modifyLiquidity calls).
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

    /// @dev Resolve the hook's net delta for both currencies after the JIT cycle.
    ///      Negative delta (hook owes PM): settle from ERC-20 on hand.
    ///      Positive delta (PM owes hook): mint as ERC-6909 claims — cannot `take` because
    ///      the swapper hasn't settled yet. Claims are redeemed in the next `_deployJIT`.
    /// @param poolId The pool to resolve deltas for (used for claim tracking).
    /// @param key    The pool key (for currency references).
    function _resolveNetDelta(PoolId poolId, PoolKey calldata key) internal {
        _resolveNetDeltaCurrency(poolId, key.currency0);
        _resolveNetDeltaCurrency(poolId, key.currency1);
    }

    /// @dev Resolve the hook's net delta for a single currency.
    /// @param poolId   The pool (for per-pool claim recording).
    /// @param currency The currency to resolve.
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

    /// @dev Validate and store a liquidity distribution. Enforces:
    ///      - 1 to MAX_BUCKETS entries
    ///      - All ticks aligned to tickSpacing
    ///      - All tick ranges valid (lower < upper)
    ///      - No zero-weight buckets
    ///      - Weights sum to exactly 10_000
    /// @param poolId      The pool to configure.
    /// @param buckets     The distribution buckets to validate and store.
    /// @param tickSpacing The pool's tick spacing (for alignment validation).
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

    /// @dev Indicative output using hypothetical multi-range JIT liquidity. Aggregates
    ///      liquidity across all distribution buckets and simulates a single SwapMath step.
    /// @param key              The pool to simulate.
    /// @param zeroForOne       Swap direction.
    /// @param amountSpecified  Swap amount (negative = exact input).
    /// @return outputAmount    Estimated output for exact-in, or required input for exact-out.
    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool, address)
        internal view override returns (uint256 outputAmount)
    {
        (, outputAmount,) = _simulateSwap(key, zeroForOne, amountSpecified);
    }

    /// @dev Price-bounded swap simulation. Clamps the caller's price limit to the outermost
    ///      bucket boundary, then simulates using the aggregate liquidity.
    /// @param key                The pool to simulate.
    /// @param zeroForOne         Swap direction.
    /// @param amountSpecified    Swap amount (negative = exact input).
    /// @param sqrtPriceLimitX96  Target price limit (Q64.96).
    /// @return amountIn          Total input consumed (including fees).
    /// @return amountOut         Total output received.
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

    /// @dev Shared simulation: compute fee and aggregate liquidity, run one SwapMath step.
    /// @param key              The pool to simulate.
    /// @param zeroForOne       Swap direction.
    /// @param amountSpecified  Swap amount (negative = exact input).
    /// @return feePips         The directional fee applied.
    /// @return outputAmount    Output tokens (for exact-in) or input tokens (for exact-out).
    /// @return sqrtPriceAfter  The sqrt price after the simulated swap step.
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

    /// @dev Read the directional fee from PricingState and compute aggregate JIT liquidity.
    /// @param key        The pool to query.
    /// @param zeroForOne Swap direction (determines which fee to use).
    /// @return feePips    The directional fee in pips.
    /// @return totalLiq   Aggregate weighted liquidity across all buckets.
    /// @return outerLower The lowest tickLower across all buckets.
    /// @return outerUpper The highest tickUpper across all buckets.
    function _swapParams(PoolKey calldata key, bool zeroForOne)
        internal view returns (uint24 feePips, uint128 totalLiq, int24 outerLower, int24 outerUpper)
    {
        PricingState memory state = pricingState[key.toId()];
        if (!state.live) return (0, 0, 0, 0);
        feePips = zeroForOne ? state.bidFeePips : state.askFeePips;
        (totalLiq, outerLower, outerUpper) = _computeAggregateJITLiquidity(key);
    }

    /// @dev Compute the aggregate JIT liquidity that would be deployed across all buckets,
    ///      and the outermost tick boundaries. Mirrors the allocation logic from `_deployJIT`
    ///      but is view-only (no state changes). Used by indicative quotes and swapToPrice.
    /// @param key         The pool to compute for.
    /// @return totalLiq   Sum of weighted liquidity across all buckets.
    /// @return outerLower The lowest tickLower across all buckets.
    /// @return outerUpper The highest tickUpper across all buckets.
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

    /// @dev Revert unless the caller is the owner or external deposits are enabled for the pool.
    /// @param poolId The pool to check authorization for.
    function _requireDepositAuth(PoolId poolId) internal view {
        if (msg.sender == owner()) return;
        if (externalDepositsEnabled[poolId]) return;
        revert Unauthorized();
    }

    /// @dev Provides PoolVault access to the PoolManager for claim operations (burn/take).
    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }
}
