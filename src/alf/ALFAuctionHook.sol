// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {toBeforeSwapDelta, BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {IALFHook, ALFHookData} from "./interfaces/IALFHook.sol";
import {AuctionHookData, TargetedQuoter} from "./types/AuctionTypes.sol";

/// @title ALFAuctionHook
/// @author Uniswap Labs
///
/// @notice Stateless atomic auction hook deployed on a virtual (zero-liquidity) pool.
///
///         The auction hook provides onchain competitive execution across multiple ALF quoter
///         hooks. It receives a set of targeted quoters from the router via hookData, queries
///         each for an indicative quote, and executes a **greedy split fill** that distributes
///         swap flow across candidates in order of indicative quality.
///
///         ## Execution Model: Greedy Split Fill
///
///         Rather than picking a single winner, the auction fills candidates sequentially from
///         best to worst indicative. Each candidate receives the full remaining swap amount with
///         a `sqrtPriceLimitX96` derived from the next candidate's current pool price. This
///         causes the v4 swap loop to terminate when the current candidate's marginal price
///         worsens to the next candidate's entry level, at which point remaining flow cascades
///         to the next candidate. The result is an approximately optimal split that:
///
///           - Fills the best-priced quoter first until price impact equalizes with the next
///           - Naturally handles quoters with different fee overrides and liquidity depths
///           - Degenerates to single-quoter execution when only one target is provided
///           - Works identically for exact-input and exact-output swaps
///
///         ## Delta Forwarding
///
///         The auction hook's virtual pool has zero liquidity — all execution happens via nested
///         `poolManager.swap()` calls on the candidates' real pools. The accumulated BalanceDelta
///         from all fills is negated into a `BeforeSwapDelta` that offsets the virtual pool's
///         swap, ensuring the auction hook's net position is zero. The outer caller receives
///         the aggregate execution as their swap result.
///
///         ## Protocol Fee
///
///         The auction hook applies its own protocol fee (separate from v4 pool-level fees):
///           - Exact input: fee is deducted from the input amount before split fill
///           - Exact output: fee is computed from the realized input after split fill
///         Fees accumulate as ERC-6909 claims on the PoolManager and are collected via
///         `collectProtocolFees()`.
///
///         ## Tolerance Enforcement
///
///         Callers may set `strictTolerancePips` in AuctionHookData to revert if aggregate
///         execution falls below the best individual indicative by more than the specified
///         tolerance. This is a downside-only check — split fill producing more output than
///         the best individual indicative (the expected case) does not trigger a revert.
///
///         ## Call Flow
///
///         ```
///         Router → poolManager.swap(auctionPool, hookData=[targets])
///           → ALFAuctionHook._beforeSwap()
///             → _prepareCandidates(): query all targets, sort by indicative
///             → _executeFills(): for each candidate (best to worst):
///                 → poolManager.swap(candidate.pool, remaining, sqrtPriceLimit=next.price)
///                   → CandidateHook._beforeSwap() [curve update, fee override]
///                   ← BalanceDelta
///                 ← accumulate delta, update remaining
///             ← (totalDelta, primaryQuoter, bestQuote)
///           ← BeforeSwapDelta (negated totalDelta + fee)
///         ← BalanceDelta (aggregate result for the swapper)
///         ```
///
///         This nested-swap pattern is explicitly supported by v4's unlock model. All deltas
///         accumulate in transient storage and must net to zero before the unlock completes.
///
/// @dev    Callers MUST encode hookData as `abi.encode(AuctionHookData(...))` with a non-empty
///         `targets` array. Each target specifies a quoter's PoolKey and optional per-quoter
///         curve update data. The auction constructs per-quoter ALFHookData that pairs the
///         shared attestation with each quoter's curve update.
contract ALFAuctionHook is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev 100% in pips. Used as the denominator for protocol fee calculations.
    uint256 internal constant MAX_PIPS = 1_000_000;

    /// @notice The auction hook's protocol fee in pips (1000 = 0.1%, 10_000 = 1%).
    /// @dev    Immutable — set at deployment. Separate from v4 pool-level protocol fees.
    uint24 public immutable protocolFeePips;

    /// @notice Contract owner. Can set the fee recipient and transfer ownership.
    address public owner;

    /// @notice Address that receives collected protocol fees.
    address public feeRecipient;

    /// @dev Tracks a quoter candidate during the split fill process.
    ///      Built during `_prepareCandidates`, sorted by indicative quality, and consumed
    ///      sequentially by `_executeFills`.
    struct FillCandidate {
        PoolKey poolKey; // The candidate's pool key (hook address embedded in poolKey.hooks)
        bytes hookData; // Constructed ALFHookData for this candidate (attestation + curve update)
        uint160 sqrtPriceX96; // The candidate's pool price at query time (used for price limits)
        uint256 indicative; // Indicative quote for the full swap amount (used for sorting)
    }

    // ──── Errors ────

    /// @dev No targeted quoter returned a valid (non-zero) indicative quote.
    error NoValidQuotes();

    /// @dev The auction hook's virtual pool must not hold liquidity.
    error LiquidityNotAllowed();

    /// @dev Exact-output split fill: aggregate output across all candidates did not satisfy
    ///      the requested amount. The swap cannot be fully filled at acceptable prices.
    error InsufficientLiquidity();

    /// @dev Strict tolerance check failed: aggregate execution deviated below the best
    ///      individual indicative by more than `strictTolerancePips`.
    /// @param indicative The best individual indicative quote (the tolerance baseline).
    /// @param executed   The actual aggregate output from the split fill.
    error QuoteDeviation(uint256 indicative, uint256 executed);

    /// @dev Caller is not the contract owner.
    error Unauthorized();

    /// @dev hookData was empty or contained no targets. The auction requires at least one
    ///      targeted quoter to execute.
    error TargetsRequired();

    // ──── Events ────

    /// @notice Emitted once per auction after all fills complete.
    /// @param primaryQuoter The first quoter in the sorted fill order (best indicative).
    /// @param zeroForOne    The swap direction.
    /// @param amountSpecified The original swap amount (negative = exact input).
    /// @param bestQuote     The best individual indicative quote (tolerance baseline).
    event AuctionExecuted(address indexed primaryQuoter, bool zeroForOne, int256 amountSpecified, uint256 bestQuote);

    /// @notice Emitted for each individual fill during a split fill execution.
    /// @dev    Useful for tracking per-quoter contributions to the aggregate result.
    ///        `amount0` and `amount1` are from the auction hook's perspective (same sign
    ///        convention as BalanceDelta).
    /// @param quoter  The quoter hook address that was filled.
    /// @param amount0 Token0 delta for this fill (negative = input, positive = output).
    /// @param amount1 Token1 delta for this fill (negative = input, positive = output).
    event FillExecuted(address indexed quoter, int128 amount0, int128 amount1);

    /// @notice Emitted when accumulated protocol fees are collected.
    /// @param currency  The currency collected.
    /// @param recipient The address that received the fees.
    /// @param amount    The amount collected.
    event ProtocolFeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);

    // ──── Constructor ────

    /// @param _poolManager    The Uniswap v4 PoolManager.
    /// @param _protocolFeePips The auction's protocol fee in pips. Immutable after deployment.
    /// @param _owner          Initial owner and fee recipient.
    constructor(IPoolManager _poolManager, uint24 _protocolFeePips, address _owner)
        BaseHook(_poolManager)
    {
        protocolFeePips = _protocolFeePips;
        owner = _owner;
        feeRecipient = _owner;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The auction hook needs:
    ///      - `beforeAddLiquidity`: to block LP on the virtual pool (it must remain empty)
    ///      - `beforeSwap`: core auction + split fill logic
    ///      - `beforeSwapReturnDelta`: to forward the aggregate nested delta to the outer swap
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          OFFCHAIN QUOTE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulate the auction without executing. Returns the single best quoter
    ///         and their indicative quote.
    /// @dev    Intended for offchain routers to pre-identify the best candidate. The router
    ///         can then either:
    ///         (a) Send a single-target hookData for gas-efficient single-quoter execution, or
    ///         (b) Send multiple targets for the full split fill.
    ///         Note: this returns the best *single* quoter, not a split fill simulation.
    /// @param zeroForOne      The swap direction.
    /// @param amountSpecified The swap amount (negative = exact input).
    /// @param hookData        ABI-encoded AuctionHookData with targets.
    /// @return winnerPoolKey  The best quoter's pool key.
    /// @return winner         The best quoter's hook address.
    /// @return bestQuote      The best indicative (output for exact-in, input for exact-out).
    /// @return winnerHookData The constructed ALFHookData to pass in nested execution.
    function quote(
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    )
        external
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        return _auction(zeroForOne, amountSpecified, hookData);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          HOOK LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Blocks all liquidity additions. The auction pool is a virtual dispatch mechanism
    ///      with zero liquidity — all real execution happens on candidates' pools.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev Core auction entry point. Orchestrates:
    ///      1. Protocol fee deduction (exact input) or deferral (exact output)
    ///      2. Greedy split fill across sorted candidates
    ///      3. Protocol fee computation from realized input (exact output)
    ///      4. Fee minting as ERC-6909 claims
    ///      5. Tolerance enforcement (downside-only)
    ///      6. Delta conversion for the virtual pool
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 feeAmount;
        int256 swapAmount = params.amountSpecified;

        // 1. Exact input: deduct protocol fee upfront, reducing the amount available for fills.
        //    The fee is taken from the swapper's input before any quoter sees it.
        if (params.amountSpecified < 0 && protocolFeePips > 0) {
            feeAmount = uint256(-params.amountSpecified) * protocolFeePips / MAX_PIPS;
            swapAmount = params.amountSpecified + int256(feeAmount); // less negative
        }

        // 2. Build sorted candidates and execute greedy split fill.
        //    Returns the accumulated delta across all fills, the primary quoter (first filled),
        //    and the best individual indicative (used as the tolerance baseline).
        (BalanceDelta totalDelta, address primaryQuoter, uint256 bestQuote) =
            _auctionAndSwap(key, params.zeroForOne, swapAmount, hookData);

        // 3. Exact output: compute fee from the total realized input across all fills.
        //    Can only be computed after execution since we don't know the input cost upfront.
        if (params.amountSpecified >= 0 && protocolFeePips > 0) {
            int128 realizedInput = params.zeroForOne ? totalDelta.amount0() : totalDelta.amount1();
            feeAmount = uint256(int256(-realizedInput)) * protocolFeePips / MAX_PIPS;
        }

        // 4. Mint ERC-6909 claims for the protocol fee. These accumulate on the PoolManager
        //    and are collected later via collectProtocolFees(). The fee currency is always
        //    the input token (token0 for zeroForOne, token1 for oneForZero).
        if (feeAmount > 0) {
            poolManager.mint(address(this), (params.zeroForOne ? key.currency0 : key.currency1).toId(), feeAmount);
        }

        // 5. Tolerance enforcement (downside-only). Split fill output should be >= the best
        //    individual indicative in the common case (splitting across multiple quoters at
        //    better marginal prices). Only revert if execution is *worse* than the baseline.
        if (hookData.length > 0) {
            uint24 tol = abi.decode(hookData, (AuctionHookData)).strictTolerancePips;
            if (tol > 0) {
                uint256 executed = _extractOutput(totalDelta, params);
                if (executed < bestQuote) {
                    uint256 dev = bestQuote - executed;
                    if (dev * MAX_PIPS > bestQuote * tol) revert QuoteDeviation(bestQuote, executed);
                }
            }
        }

        emit AuctionExecuted(primaryQuoter, params.zeroForOne, params.amountSpecified, bestQuote);

        // 6. Convert the accumulated BalanceDelta into a BeforeSwapDelta that offsets the
        //    virtual pool's swap. The negation ensures the auction hook's net position is zero.
        //    The protocol fee is added to the appropriate delta component so the swapper pays it.
        return (IHooks.beforeSwap.selector, _toBeforeSwapDelta(totalDelta, params, feeAmount), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          AUCTION INTERNALS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Top-level auction-and-execute. Detects the execution mode from the hookData:
    ///
    ///      **Autonomous mode** (all targets have amountSpecified = 0):
    ///        Queries indicatives, sorts candidates by quote quality, and executes a greedy
    ///        split fill with price limits. Fully self-contained.
    ///
    ///      **Pre-planned mode** (any target has amountSpecified != 0):
    ///        Executes targets in the given order with their specified amounts. A target
    ///        with amountSpecified = 0 receives whatever remains. Skips sorting. Indicatives
    ///        are queried only if tolerance enforcement is enabled.
    ///
    /// @param zeroForOne The swap direction.
    /// @param swapAmount The swap amount (after protocol fee deduction for exact input).
    /// @param hookData   ABI-encoded AuctionHookData from the caller.
    /// @return totalDelta     Accumulated BalanceDelta across all fills.
    /// @return primaryQuoter  The first quoter in fill order.
    /// @return bestQuote      The best individual indicative (tolerance baseline). 0 if skipped.
    function _auctionAndSwap(PoolKey calldata, bool zeroForOne, int256 swapAmount, bytes calldata hookData)
        internal
        returns (BalanceDelta totalDelta, address primaryQuoter, uint256 bestQuote)
    {
        if (hookData.length == 0) revert TargetsRequired();
        AuctionHookData memory ahd = abi.decode(hookData, (AuctionHookData));
        if (ahd.targets.length == 0) revert TargetsRequired();

        if (_isPrePlanned(ahd.targets)) {
            // Pre-planned: router-optimized execution order and amounts
            (totalDelta, primaryQuoter, bestQuote) =
                _executePrePlanned(ahd, zeroForOne, swapAmount);
        } else {
            // Autonomous: self-contained split fill with indicative sorting
            (FillCandidate[] memory candidates, uint256 count, uint256 bestIndividual) =
                _prepareCandidates(zeroForOne, swapAmount, ahd);
            bestQuote = bestIndividual;
            primaryQuoter = address(candidates[0].poolKey.hooks);
            totalDelta = _executeFills(candidates, count, zeroForOne, swapAmount);
        }
    }

    /// @dev Single-winner auction used by the `quote()` view function. Iterates all targets
    ///      and returns the quoter with the best indicative quote. Does NOT execute any swaps.
    /// @param zeroForOne      The swap direction.
    /// @param amountSpecified The swap amount (negative = exact input).
    /// @param hookData        ABI-encoded AuctionHookData.
    /// @return winnerPoolKey  The best quoter's pool key.
    /// @return winner         The best quoter's hook address.
    /// @return bestQuote      The best indicative quote.
    /// @return winnerHookData The constructed ALFHookData for the winner.
    function _auction(
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    )
        internal
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        if (hookData.length == 0) revert TargetsRequired();

        AuctionHookData memory ahd = abi.decode(hookData, (AuctionHookData));
        if (ahd.targets.length == 0) revert TargetsRequired();

        (winnerPoolKey, winner, bestQuote, winnerHookData) =
            _runTargeted(zeroForOne, amountSpecified, ahd.attestationData, ahd.targets);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                         QUOTER QUERY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Iterate targets and return the single best quoter. Used by `quote()` for the
    ///      offchain view path. Each target is queried via `_queryTarget`; the best indicative
    ///      wins (highest output for exact-in, lowest input for exact-out).
    function _runTargeted(
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory attestationData,
        TargetedQuoter[] memory targets
    )
        internal
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        bool isExactInput = amountSpecified < 0;
        bool foundValid;

        for (uint256 i = 0; i < targets.length; i++) {
            (uint256 q, bytes memory quoterHookData) =
                _queryTarget(targets[i], attestationData, zeroForOne, amountSpecified);

            if (q == 0) continue;

            bool isBetter = !foundValid || (isExactInput ? q > bestQuote : q < bestQuote);

            if (isBetter) {
                bestQuote = q;
                winnerPoolKey = targets[i].poolKey;
                winner = address(targets[i].poolKey.hooks);
                winnerHookData = quoterHookData;
                foundValid = true;
            }
        }

        if (!foundValid) revert NoValidQuotes();
    }

    /// @dev Query a single targeted quoter for its indicative quote. Performs three checks:
    ///      1. `isLive()` — skip quoters that report themselves as offline
    ///      2. `maxGas()` — read the declared gas budget for the indicative call
    ///      3. `getIndicativeQuote()` — call with the gas budget, catch failures
    ///
    ///      Returns (0, "") if any step fails. Failures are soft — the quoter is skipped
    ///      without reverting the entire auction.
    ///
    ///      Constructs the per-quoter ALFHookData by pairing the shared attestation data
    ///      with the target's quoter-specific curve update data.
    /// @param target          The targeted quoter (pool key + curve update data).
    /// @param attestationData Shared attestation payload from the AuctionHookData.
    /// @param zeroForOne      The swap direction.
    /// @param amountSpecified The swap amount.
    /// @return q              The indicative quote (0 if invalid/failed).
    /// @return quoterHookData The constructed ALFHookData for nested execution.
    function _queryTarget(
        TargetedQuoter memory target,
        bytes memory attestationData,
        bool zeroForOne,
        int256 amountSpecified
    ) internal view returns (uint256 q, bytes memory quoterHookData) {
        address hook = address(target.poolKey.hooks);

        // 1. Liveness check — skip offline quoters
        try IALFHook(hook).isLive() returns (bool live) {
            if (!live) return (0, "");
        } catch {
            return (0, "");
        }

        // 2. Gas budget — used to cap the indicative call
        uint32 gasLimit;
        try IALFHook(hook).maxGas() returns (uint32 mg) {
            gasLimit = mg;
        } catch {
            return (0, "");
        }

        // 3. Build per-quoter hookData and query the indicative
        quoterHookData =
            abi.encode(ALFHookData({attestationData: attestationData, curveUpdateData: target.curveUpdateData}));

        try IALFHook(hook).getIndicativeQuote{gas: gasLimit}(
            target.poolKey, zeroForOne, amountSpecified, quoterHookData
        ) returns (
            uint256 indicative
        ) {
            q = indicative;
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          SPLIT FILL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Returns true if any target has a non-zero amountSpecified, indicating the router
    ///      has pre-planned the split and the auction should execute in the given order.
    function _isPrePlanned(TargetedQuoter[] memory targets) internal pure returns (bool) {
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i].amountSpecified != 0) return true;
        }
        return false;
    }

    /// @dev Pre-planned execution: router has determined the optimal fill order and per-quoter
    ///      amounts. Execute targets in the given order with their specified amounts.
    ///
    ///      A target with amountSpecified = 0 acts as a "fill remaining" catch-all, receiving
    ///      whatever input/output is left after prior fills. Typically the last target.
    ///
    ///      Skips indicative queries and sorting for gas efficiency. If tolerance checking is
    ///      enabled (strictTolerancePips > 0), indicatives are queried on-demand for the
    ///      tolerance baseline.
    ///
    /// @param ahd         Decoded AuctionHookData.
    /// @param zeroForOne  The swap direction.
    /// @param swapAmount  The total swap amount.
    /// @return totalDelta     Accumulated BalanceDelta across all fills.
    /// @return primaryQuoter  The first target's hook address.
    /// @return bestQuote      Best individual indicative (0 if tolerance is disabled).
    function _executePrePlanned(AuctionHookData memory ahd, bool zeroForOne, int256 swapAmount)
        internal
        returns (BalanceDelta totalDelta, address primaryQuoter, uint256 bestQuote)
    {
        primaryQuoter = address(ahd.targets[0].poolKey.hooks);

        // Query indicatives only if tolerance checking is enabled
        if (ahd.strictTolerancePips > 0) {
            bestQuote = _queryBestIndicative(ahd, zeroForOne, swapAmount);
        }

        totalDelta = _runPrePlannedFills(ahd, zeroForOne, swapAmount);
    }

    /// @dev Query all targets for indicatives and return the best one.
    ///      Used by pre-planned mode only when tolerance enforcement is enabled.
    function _queryBestIndicative(AuctionHookData memory ahd, bool zeroForOne, int256 swapAmount)
        internal
        view
        returns (uint256 best)
    {
        bool exactInput = swapAmount < 0;
        for (uint256 i = 0; i < ahd.targets.length; i++) {
            (uint256 q,) = _queryTarget(ahd.targets[i], ahd.attestationData, zeroForOne, swapAmount);
            if (q == 0) continue;
            if (best == 0 || (exactInput ? q > best : q < best)) {
                best = q;
            }
        }
    }

    /// @dev Execute targets in the given order with their pre-planned amounts.
    ///      Separated from _executePrePlanned to manage stack depth.
    function _runPrePlannedFills(AuctionHookData memory ahd, bool zeroForOne, int256 swapAmount)
        internal
        returns (BalanceDelta totalDelta)
    {
        int256 remaining = swapAmount;
        bool exactInput = swapAmount < 0;
        uint160 noLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        for (uint256 i = 0; i < ahd.targets.length && remaining != 0; i++) {
            BalanceDelta delta;
            {
                bytes memory quoterHookData = abi.encode(
                    ALFHookData({attestationData: ahd.attestationData, curveUpdateData: ahd.targets[i].curveUpdateData})
                );
                int256 thisAmount = ahd.targets[i].amountSpecified != 0 ? ahd.targets[i].amountSpecified : remaining;

                delta = poolManager.swap(
                    ahd.targets[i].poolKey,
                    SwapParams({zeroForOne: zeroForOne, amountSpecified: thisAmount, sqrtPriceLimitX96: noLimit}),
                    quoterHookData
                );
            }

            int128 filled = exactInput
                ? (zeroForOne ? delta.amount0() : delta.amount1())
                : (zeroForOne ? delta.amount1() : delta.amount0());
            remaining -= int256(filled);
            totalDelta = totalDelta + delta;

            emit FillExecuted(address(ahd.targets[i].poolKey.hooks), delta.amount0(), delta.amount1());
        }

        if (!exactInput && remaining > 0) revert InsufficientLiquidity();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                    AUTONOMOUS SPLIT FILL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Phase 1 of autonomous split fill: build and sort the candidate array.
    ///
    ///      For each target in the AuctionHookData:
    ///        - Query the quoter for an indicative quote (via _queryTarget)
    ///        - Read the quoter's pool sqrtPriceX96 (for price limit computation)
    ///        - If valid (non-zero indicative), add to the candidates array
    ///
    ///      After collection, candidates are sorted by indicative quality using insertion
    ///      sort. The indicative is the best available signal for fill ordering because it
    ///      captures the combined effect of the quoter's fee override, liquidity depth, and
    ///      price impact in a single number. The sqrtPriceX96 is retained for price limit
    ///      computation during execution.
    ///
    ///      Insertion sort is O(n²) but optimal for the expected candidate set size (3-5).
    ///      The router controls the target count and should keep it small to bound gas.
    ///
    /// @param zeroForOne The swap direction.
    /// @param swapAmount The swap amount (after any fee deduction).
    /// @param ahd        Decoded AuctionHookData.
    /// @return candidates    Array of valid candidates, sorted best-first.
    /// @return count         Number of valid candidates (may be < candidates.length).
    /// @return bestIndividual The best individual indicative quote (tolerance baseline).
    function _prepareCandidates(bool zeroForOne, int256 swapAmount, AuctionHookData memory ahd)
        internal
        view
        returns (FillCandidate[] memory candidates, uint256 count, uint256 bestIndividual)
    {
        bool isExactInput = swapAmount < 0;
        candidates = new FillCandidate[](ahd.targets.length);

        for (uint256 i = 0; i < ahd.targets.length; i++) {
            (uint256 q, bytes memory quoterHookData) =
                _queryTarget(ahd.targets[i], ahd.attestationData, zeroForOne, swapAmount);
            if (q == 0) continue;

            // Read the quoter's current pool price for price limit computation during fills.
            // This is a snapshot — the price won't change before we fill this candidate because
            // each pool is filled at most once during the split fill.
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(ahd.targets[i].poolKey.toId());

            candidates[count] = FillCandidate({
                poolKey: ahd.targets[i].poolKey,
                hookData: quoterHookData,
                sqrtPriceX96: sqrtPriceX96,
                indicative: q
            });

            // Track the best individual indicative for tolerance checking.
            // For exact input: highest output = best. For exact output: lowest input = best.
            if (count == 0 || (isExactInput ? q > bestIndividual : q < bestIndividual)) {
                bestIndividual = q;
            }
            count++;
        }

        if (count == 0) revert NoValidQuotes();

        // Insertion sort by indicative quality. Best quote goes to index 0.
        //   exact input:  highest output first (descending)
        //   exact output: lowest required input first (ascending)
        for (uint256 i = 1; i < count; i++) {
            FillCandidate memory key = candidates[i];
            uint256 j = i;
            while (j > 0 && _worseQuote(candidates[j - 1].indicative, key.indicative, isExactInput)) {
                candidates[j] = candidates[j - 1];
                j--;
            }
            candidates[j] = key;
        }
    }

    /// @dev Phase 2 of split fill: execute sequential swaps across sorted candidates.
    ///
    ///      For each candidate (best indicative first):
    ///        1. Compute a sqrtPriceLimitX96 from the next candidate's pool price. This causes
    ///           the v4 swap loop to terminate when the current candidate's marginal price
    ///           worsens to the next candidate's entry level (the optimal crossover point).
    ///        2. Execute a nested poolManager.swap() with the full remaining amount and the
    ///           computed price limit. The swap fills as much as possible within the limit.
    ///        3. Extract the "filled" amount from the delta and update remaining.
    ///        4. Accumulate the delta into totalDelta using BalanceDelta addition.
    ///
    ///      The loop terminates when remaining reaches zero (fully filled) or all candidates
    ///      are exhausted.
    ///
    ///      ## Price Limit Edge Case
    ///
    ///      When two candidates share the same sqrtPrice (common when pools are initialized at
    ///      the same tick), the next candidate's price can't serve as a valid limit because v4
    ///      requires `limit < currentPrice` (zeroForOne) or `limit > currentPrice` (oneForZero).
    ///      In this case, the limit falls through to the extreme (MIN/MAX), which means the
    ///      current candidate is fully drained before moving to the next. This is correct but
    ///      not optimal for the degenerate equal-price case — acceptable since the sort by
    ///      indicative ensures the better quoter (by fee/liquidity) fills first regardless.
    ///
    ///      ## Remaining Tracking
    ///
    ///      For exact input (amountSpecified < 0):
    ///        `remaining` starts negative. Each fill's consumed input (negative delta) is
    ///        subtracted, moving remaining toward zero.
    ///
    ///      For exact output (amountSpecified > 0):
    ///        `remaining` starts positive. Each fill's received output (positive delta) is
    ///        subtracted, moving remaining toward zero. If remaining > 0 after all candidates
    ///        are exhausted, the swap cannot be fully filled and the function reverts.
    ///
    /// @param candidates Sorted array of fill candidates (best first).
    /// @param count      Number of valid candidates in the array.
    /// @param zeroForOne The swap direction.
    /// @param swapAmount The total swap amount to fill.
    /// @return totalDelta The accumulated BalanceDelta across all fills.
    function _executeFills(FillCandidate[] memory candidates, uint256 count, bool zeroForOne, int256 swapAmount)
        internal
        returns (BalanceDelta totalDelta)
    {
        int256 remaining = swapAmount;
        bool exactInput = swapAmount < 0;

        for (uint256 i = 0; i < count && remaining != 0; i++) {
            // Compute the price limit for this fill. The next candidate's sqrtPrice acts as
            // the crossover threshold — stop filling the current candidate when its marginal
            // price drops to this level, and let remaining flow cascade to the next candidate.
            uint160 limit;
            if (i + 1 < count) {
                uint160 nextPrice = candidates[i + 1].sqrtPriceX96;
                // Only use as a limit if it's strictly on the correct side of the current price.
                // zeroForOne: price decreases, so limit must be < current to constrain.
                // oneForZero: price increases, so limit must be > current to constrain.
                bool validLimit = zeroForOne
                    ? nextPrice < candidates[i].sqrtPriceX96
                    : nextPrice > candidates[i].sqrtPriceX96;
                limit = validLimit
                    ? nextPrice
                    : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            } else {
                // Last candidate: no limit, fill as much as possible.
                limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            }

            // Execute the nested swap on this candidate's pool.
            BalanceDelta delta = poolManager.swap(
                candidates[i].poolKey,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: remaining, sqrtPriceLimitX96: limit}),
                candidates[i].hookData
            );

            // Extract the "filled" component from the delta and update remaining.
            //   exact input:  filled = input consumed (negative), so remaining -= negative → less negative
            //   exact output: filled = output received (positive), so remaining -= positive → less positive
            // Both converge remaining toward zero.
            int128 filled = exactInput
                ? (zeroForOne ? delta.amount0() : delta.amount1())
                : (zeroForOne ? delta.amount1() : delta.amount0());
            remaining -= int256(filled);
            totalDelta = totalDelta + delta;

            emit FillExecuted(address(candidates[i].poolKey.hooks), delta.amount0(), delta.amount1());
        }

        // Exact output: if remaining > 0 after all candidates, the aggregate liquidity wasn't
        // sufficient to fill the requested output. The swapper's transaction must revert.
        if (!exactInput && remaining > 0) revert InsufficientLiquidity();
    }

    /// @dev Comparison function for insertion sort. Returns true if indicative `a` is worse
    ///      than `b` for the given swap type, meaning `b` should be sorted before `a`.
    ///        exact input:  higher output = better, so a < b means a is worse
    ///        exact output: lower input   = better, so a > b means a is worse
    function _worseQuote(uint256 a, uint256 b, bool isExactInput) internal pure returns (bool) {
        return isExactInput ? a < b : a > b;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          DELTA HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Extract the "output" amount from a BalanceDelta for tolerance comparison.
    ///
    ///      For exact input: output is the received token (positive delta on the output side).
    ///      For exact output: "output" per IALFHook convention is the required input (abs of
    ///      the negative delta on the input side).
    ///
    ///      Used to compare aggregate execution against the best individual indicative.
    /// @param delta  The accumulated BalanceDelta from all fills.
    /// @param params The original swap parameters.
    /// @return The output amount as a positive uint256.
    function _extractOutput(BalanceDelta delta, SwapParams calldata params) internal pure returns (uint256) {
        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            int128 out = params.zeroForOne ? delta.amount1() : delta.amount0();
            return uint256(int256(out));
        } else {
            int128 inp = params.zeroForOne ? delta.amount0() : delta.amount1();
            return uint256(int256(-inp));
        }
    }

    /// @dev Convert the accumulated BalanceDelta from nested fills into a BeforeSwapDelta
    ///      that offsets the virtual pool's swap.
    ///
    ///      The BeforeSwapDelta has two components: `specified` and `unspecified`.
    ///        - specified:   maps to the token the swapper specified (input for exact-in, output for exact-out)
    ///        - unspecified: maps to the other token
    ///
    ///      The nested delta is negated so the virtual pool's swap produces the inverse
    ///      position, netting the auction hook's balance to zero. The protocol fee is added
    ///      to the appropriate component so the swapper pays it:
    ///        - exact input:  fee added to specified (increases the input the swapper pays)
    ///        - exact output: fee added to unspecified (increases the input the swapper pays)
    ///
    /// @param delta     The accumulated BalanceDelta from all nested fills.
    /// @param params    The original swap parameters.
    /// @param feeAmount The protocol fee amount (0 if no fee).
    /// @return The BeforeSwapDelta to return from _beforeSwap.
    function _toBeforeSwapDelta(BalanceDelta delta, SwapParams calldata params, uint256 feeAmount)
        internal
        pure
        returns (BeforeSwapDelta)
    {
        bool isExactInput = params.amountSpecified < 0;
        int128 specified;
        int128 unspecified;

        // Map (amount0, amount1) → (specified, unspecified) based on direction and swap type.
        // For exact-input zeroForOne: specified = amount0, unspecified = amount1
        // For exact-input oneForZero: specified = amount1, unspecified = amount0
        // (and vice versa for exact-output, where the specified token is the output)
        if (isExactInput == params.zeroForOne) {
            specified = -delta.amount0();
            unspecified = -delta.amount1();
        } else {
            specified = -delta.amount1();
            unspecified = -delta.amount0();
        }

        // Add the protocol fee to the appropriate component.
        if (feeAmount > 0) {
            if (isExactInput) {
                specified += int128(uint128(feeAmount));
            } else {
                unspecified += int128(uint128(feeAmount));
            }
        }

        return toBeforeSwapDelta(specified, unspecified);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          FEE COLLECTION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Collect accumulated protocol fees for a currency.
    /// @dev    Fees accumulate as ERC-6909 claims on the PoolManager during auction execution.
    ///        This function burns the claims and takes the underlying tokens, transferring
    ///        them to `feeRecipient`. Callable by anyone (no access control needed since
    ///        fees always go to feeRecipient).
    /// @param currency The currency to collect fees for.
    function collectProtocolFees(Currency currency) external {
        uint256 claims = poolManager.balanceOf(address(this), currency.toId());
        if (claims == 0) return;
        poolManager.unlock(abi.encode(currency, claims, feeRecipient));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Called by PoolManager during collectProtocolFees(). Burns ERC-6909 claims and
    ///      takes the underlying tokens to the fee recipient.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (Currency currency, uint256 amount, address recipient) = abi.decode(data, (Currency, uint256, address));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
        emit ProtocolFeesCollected(currency, recipient, amount);
        return "";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          GOVERNANCE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Set the fee recipient address.
    /// @param _feeRecipient The new fee recipient.
    function setFeeRecipient(address _feeRecipient) external {
        if (msg.sender != owner) revert Unauthorized();
        feeRecipient = _feeRecipient;
    }

    /// @notice Transfer ownership of the auction hook.
    /// @param newOwner The new owner address.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        owner = newOwner;
    }
}
