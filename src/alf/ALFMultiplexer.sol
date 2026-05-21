// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {toBeforeSwapDelta, BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {QuoterRevert} from "@uniswap/v4-periphery/src/libraries/QuoterRevert.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IALFHook, ALFHookData} from "./interfaces/IALFHook.sol";
import {SwapSimulator} from "./libraries/SwapSimulator.sol";
import {MultiplexerHookData, TargetedQuoter} from "./types/MultiplexerTypes.sol";
import {IIndicativeQuote} from "../interfaces/IIndicativeQuote.sol";

/// @title ALFMultiplexer
/// @author Uniswap Labs
///
/// @notice Stateless atomic multiplexer deployed on a virtual (zero-liquidity) pool.
///
///         The multiplexer provides onchain competitive execution across multiple ALF quoter
///         hooks. It receives a set of targeted quoters from the router via hookData, simulates
///         each candidate through the real v4 swap path, and executes a **greedy split fill**
///         that distributes swap flow across candidates in order of indicative quality.
///
///         ## Execution Model: Greedy Split Fill
///
///         Rather than picking a single winner, the multiplexer fills candidates sequentially from
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
///         The multiplexer's virtual pool has zero liquidity — all execution happens via nested
///         `poolManager.swap()` calls on the candidates' real pools. The accumulated BalanceDelta
///         from all fills is negated into a `BeforeSwapDelta` that offsets the virtual pool's
///         swap, ensuring the multiplexer's net position is zero. The outer caller receives
///         the aggregate execution as their swap result.
///
///         ## Protocol Fees
///
///         The multiplexer does not charge a protocol fee on its own virtual pool. v4 charges
///         the protocol fee natively on each NESTED candidate swap (against the candidate's
///         own pool), so layering an additional multiplexer-level fee would double-charge
///         users. Operators who want to collect fees through this routing path SHOULD
///         configure them on the underlying candidate pools.
///
///         ## Tolerance Enforcement
///
///         Callers may set `strictTolerancePips` in MultiplexerHookData to revert if aggregate
///         execution falls below the best individual indicative by more than the specified
///         tolerance. This is a downside-only check — split fill producing more output than
///         the best individual indicative (the expected case) does not trigger a revert.
///
///         ## Call Flow
///
///         ```
///         Router → poolManager.swap(multiplexerPool, hookData=[targets])
///           → ALFMultiplexer._beforeSwap()
///             → _prepareCandidates(): simulate all targets, sort by indicative
///             → _executeFills(): for each candidate (best to worst):
///                 → poolManager.swap(candidate.pool, remaining, sqrtPriceLimit=next.price)
///                   → CandidateHook._beforeSwap() [curve update, fee override]
///                   ← BalanceDelta
///                 ← accumulate delta, update remaining
///             ← (totalDelta, primaryQuoter, bestQuote)
///           ← BeforeSwapDelta (negated totalDelta)
///         ← BalanceDelta (aggregate result for the swapper)
///         ```
///
///         This nested-swap pattern is explicitly supported by v4's unlock model. All deltas
///         accumulate in transient storage and must net to zero before the unlock completes.
///
/// @dev    Callers MUST encode hookData as `abi.encode(MultiplexerHookData(...))` with a non-empty
///         `targets` array. Each target specifies a quoter's PoolKey and optional per-quoter
///         curve update data. The multiplexer constructs per-quoter ALFHookData that pairs the
///         shared attestation with each quoter's curve update.
/// @custom:security-contact security@uniswap.org
contract ALFMultiplexer is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using QuoterRevert for uint256;

    /// @dev Tracks a quoter candidate during the split fill process. Built during
    ///      `_prepareCandidates`, sorted by indicative quality, and consumed sequentially by
    ///      `_executeFills`.
    /// @param poolKey The candidate's pool key (hook address embedded in `poolKey.hooks`).
    /// @param hookData Constructed ALFHookData for this candidate (attestation + curve update).
    /// @param sqrtPriceX96 The candidate's pool price at query time, used for price limits.
    /// @param indicative Indicative quote for the full swap amount, used for sorting.
    struct FillCandidate {
        PoolKey poolKey;
        bytes hookData;
        uint160 sqrtPriceX96;
        uint256 indicative;
    }

    // ──── Errors ────

    /// @dev No targeted quoter returned a valid (non-zero) indicative quote.
    error NoValidQuotes();

    /// @dev The multiplexer's virtual pool must not hold liquidity.
    error LiquidityNotAllowed();

    /// @dev Exact-output split fill: aggregate output across all candidates did not satisfy
    ///      the requested amount. The swap cannot be fully filled at acceptable prices.
    error InsufficientLiquidity();

    /// @dev Strict tolerance check failed. For exact input, effective output was below the
    ///      best individual indicative output by more than `strictTolerancePips`; for exact
    ///      output, effective input paid was above the best individual indicative input by
    ///      more than `strictTolerancePips`.
    /// @param indicative The best individual indicative quote used as the tolerance baseline
    ///                   (output for exact input, input for exact output).
    /// @param executed The effective executed amount compared to the baseline (output for
    ///                 exact input, input paid for exact output).
    error QuoteDeviation(uint256 indicative, uint256 executed);

    /// @dev Quote helper may only be called through an external self-call.
    error NotSelf();

    /// @dev hookData was empty or contained no targets. The multiplexer requires at least one
    ///      targeted quoter to execute.
    error TargetsRequired();

    /// @dev `strictTolerancePips > 0` but no indicative baseline could be established (every
    ///      candidate's quote query failed). Strict tolerance has nothing to compare against,
    ///      so the swap is refused — the caller asked for a guarantee the multiplexer cannot make.
    error MissingQuoteBaseline();

    /// @dev Pre-planned mode received a target whose `amountSpecified` sign does not match the
    ///      outer swap direction (e.g., exact-input outer with an exact-output target). Allowing
    ///      mismatched signs would make the catch-all leg take the opposite swap direction and
    ///      corrupt the aggregate accounting.
    error TargetDirectionMismatch();

    /// @dev Pre-planned mode received targets whose summed `|amountSpecified|` exceeds
    ///      `|swapAmount|`. Over-allocating across legs flips the `remaining` tracker's sign and
    ///      produces malformed downstream fills.
    error TargetsOverAllocated();

    // ──── Events ────

    /// @notice Emitted once per multiplexer execution after all fills complete.
    /// @param primaryQuoter The first quoter in the sorted fill order (best indicative).
    /// @param zeroForOne    The swap direction.
    /// @param amountSpecified The original swap amount (negative = exact input).
    /// @param bestQuote     The best individual indicative quote (tolerance baseline).
    event MultiplexerExecuted(
        address indexed primaryQuoter, bool zeroForOne, int256 amountSpecified, uint256 bestQuote
    );

    /// @notice Emitted for each individual fill during a split fill execution.
    /// @dev    Useful for tracking per-quoter contributions to the aggregate result.
    ///        `amount0` and `amount1` are from the multiplexer's perspective (same sign
    ///        convention as BalanceDelta).
    /// @param quoter  The quoter hook address that was filled.
    /// @param amount0 Token0 delta for this fill (negative = input, positive = output).
    /// @param amount1 Token1 delta for this fill (negative = input, positive = output).
    event FillExecuted(address indexed quoter, int128 amount0, int128 amount1);

    /// @notice Emitted when a candidate fill reverts and is soft-skipped during a split fill.
    /// @dev    The multiplexer continues with the next candidate. Routers can monitor this event
    ///         to deprioritize the offending quoter in their reputation model.
    /// @param quoter The quoter hook address whose fill failed.
    event FillFailed(address indexed quoter);

    // ──── Constructor ────

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param _owner       Initial owner.
    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) Ownable(_owner) {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                          HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The multiplexer needs:
    ///      - `beforeAddLiquidity`: to block LP on the virtual pool (it must remain empty)
    ///      - `beforeDonate`: to block donations to the virtual pool (no LP can ever
    ///        claim them, so they would be permanently locked in PM accounting)
    ///      - `beforeSwap`: core multiplexer + split fill logic
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
            beforeDonate: true,
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

    /// @notice Simulate the multiplexer without executing. Returns the single best quoter
    ///         and their indicative quote.
    /// @dev    Intended for offchain routers to pre-identify the best candidate. The router
    ///         can then either:
    ///         (a) Send a single-target hookData for gas-efficient single-quoter execution, or
    ///         (b) Send multiple targets for the full split fill.
    ///         Note: this returns the best *single* quoter, not a split fill simulation.
    /// @param zeroForOne      The swap direction.
    /// @param amountSpecified The swap amount (negative = exact input).
    /// @param hookData        ABI-encoded MultiplexerHookData with targets.
    /// @return winnerPoolKey  The best quoter's pool key.
    /// @return winner         The best quoter's hook address.
    /// @return bestQuote      The best indicative (output for exact-in, input for exact-out).
    /// @return winnerHookData The constructed ALFHookData to pass in nested execution.
    function quote(bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        return _multiplex(zeroForOne, amountSpecified, hookData);
    }

    /// @dev External self-call target used to quote a candidate through the real v4 swap path.
    ///      The outer caller catches the deliberate `QuoteSwap` revert. Reverting here rolls
    ///      back the simulated candidate swap, including hook state, PoolManager state, ERC-20
    ///      transfers, vault calls, and transient deltas. Reverts with {NotSelf} if invoked by
    ///      any caller other than this contract.
    /// @param poolKey        The candidate quoter's pool key.
    /// @param zeroForOne     The swap direction.
    /// @param amountSpecified The swap amount (negative = exact input, positive = exact output).
    /// @param hookData        ABI-encoded ALFHookData for the candidate.
    /// @return Always reverts before returning (function always reverts via {QuoterRevert.QuoteSwap}).
    function quoteTargetBySwap(
        PoolKey calldata poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    ) external returns (uint256) {
        if (msg.sender != address(this)) revert NotSelf();

        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );

        uint256 quoteAmount;
        if (amountSpecified < 0) {
            quoteAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        } else {
            quoteAmount = zeroForOne ? uint256(int256(-delta.amount0())) : uint256(int256(-delta.amount1()));
        }

        quoteAmount.revertQuote();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          HOOK LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Blocks all liquidity additions. The multiplexer pool is a virtual dispatch mechanism
    ///      with zero liquidity — all real execution happens on candidates' pools.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev Blocks all donations. The virtual pool has no LP positions and never will, so any
    ///      donation would be permanently locked in PoolManager accounting. Reverts unconditionally.
    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev Core multiplexer entry point. Orchestrates:
    ///      1. Greedy split fill across sorted candidates
    ///      2. Protocol fee application (reads fee from slot0, takes to token jar)
    ///      3. Tolerance enforcement (downside-only)
    ///      4. Delta conversion for the virtual pool
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. Build sorted candidates and execute greedy split fill.
        (BalanceDelta totalDelta, address primaryQuoter, uint256 bestQuote) =
            _multiplexAndSwap(key, params.zeroForOne, params.amountSpecified, hookData);

        // 2. Tolerance enforcement (downside-only). The "downside" direction depends on swap
        //    type: exact-input swappers want MORE output (so executed < bestQuote is bad);
        //    exact-output swappers want LESS input (so executed > bestQuote is bad). Both
        //    `executed` and `bestQuote` are in the candidate frame — v4 charges each
        //    candidate's protocol fee natively on the nested swap and the multiplexer
        //    itself does not charge a fee on top, so no frame conversion is needed.
        if (hookData.length > 0) {
            uint256 tol = abi.decode(hookData, (MultiplexerHookData)).strictTolerancePips;
            if (tol > 0) {
                // No baseline ⇒ no protection. Refuse rather than silently accept.
                if (bestQuote == 0) revert MissingQuoteBaseline();

                uint256 executed = _extractOutput(totalDelta, params);
                if (params.amountSpecified < 0) {
                    if (executed < bestQuote) {
                        uint256 dev = bestQuote - executed;
                        if (dev * 1_000_000 > bestQuote * tol) revert QuoteDeviation(bestQuote, executed);
                    }
                } else {
                    if (executed > bestQuote) {
                        uint256 dev = executed - bestQuote;
                        if (dev * 1_000_000 > bestQuote * tol) revert QuoteDeviation(bestQuote, executed);
                    }
                }
            }
        }

        emit MultiplexerExecuted(primaryQuoter, params.zeroForOne, params.amountSpecified, bestQuote);

        // 3. Convert BalanceDelta → BeforeSwapDelta to offset the virtual pool's swap.
        return (IHooks.beforeSwap.selector, _toBeforeSwapDelta(totalDelta, params), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          AUCTION INTERNALS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Top-level multiplex-and-execute. Detects the execution mode from the hookData:
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
    /// @param hookData   ABI-encoded MultiplexerHookData from the caller.
    /// @return totalDelta     Accumulated BalanceDelta across all fills.
    /// @return primaryQuoter  The first quoter in fill order.
    /// @return bestQuote      The best individual indicative (tolerance baseline). 0 if skipped.
    function _multiplexAndSwap(PoolKey calldata, bool zeroForOne, int256 swapAmount, bytes calldata hookData)
        internal
        returns (BalanceDelta totalDelta, address primaryQuoter, uint256 bestQuote)
    {
        if (hookData.length == 0) revert TargetsRequired();
        MultiplexerHookData memory ahd = abi.decode(hookData, (MultiplexerHookData));
        if (ahd.targets.length == 0) revert TargetsRequired();

        if (_isPrePlanned(ahd.targets)) {
            // Pre-planned: router-optimized execution order and amounts
            (totalDelta, primaryQuoter, bestQuote) = _executePrePlanned(ahd, zeroForOne, swapAmount);
        } else {
            // Autonomous: self-contained split fill with indicative sorting
            (FillCandidate[] memory candidates, uint256 count, uint256 bestIndividual) =
                _prepareCandidates(zeroForOne, swapAmount, ahd);
            bestQuote = bestIndividual;
            primaryQuoter = address(candidates[0].poolKey.hooks);
            totalDelta = _executeFills(candidates, count, zeroForOne, swapAmount);
        }
    }

    /// @dev Single-winner selection used by the `quote()` view function. Iterates all targets
    ///      and returns the quoter with the best indicative quote. Does NOT execute any swaps.
    /// @param zeroForOne      The swap direction.
    /// @param amountSpecified The swap amount (negative = exact input).
    /// @param hookData        ABI-encoded MultiplexerHookData.
    /// @return winnerPoolKey  The best quoter's pool key.
    /// @return winner         The best quoter's hook address.
    /// @return bestQuote      The best indicative quote.
    /// @return winnerHookData The constructed ALFHookData for the winner.
    function _multiplex(bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        internal
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        if (hookData.length == 0) revert TargetsRequired();

        MultiplexerHookData memory ahd = abi.decode(hookData, (MultiplexerHookData));
        if (ahd.targets.length == 0) revert TargetsRequired();

        (winnerPoolKey, winner, bestQuote, winnerHookData) =
            _runTargeted(zeroForOne, amountSpecified, ahd.attestationData, ahd.targets);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                         QUOTER QUERY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Iterate targets and return the single best quoter. Used by `quote()` for the
    ///      offchain view path. Each target is queried via `_queryTargetView`; the best
    ///      indicative wins (highest output for exact-in, lowest input for exact-out).
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
                _queryTargetView(targets[i], attestationData, zeroForOne, amountSpecified);

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
    ///      without reverting the entire multiplexer.
    ///
    ///      Constructs the per-quoter ALFHookData by pairing the shared attestation data
    ///      with the target's quoter-specific curve update data.
    /// @param target          The targeted quoter (pool key + curve update data).
    /// @param attestationData Shared attestation payload from the MultiplexerHookData.
    /// @param zeroForOne      The swap direction.
    /// @param amountSpecified The swap amount.
    /// @return q              The indicative quote (0 if invalid/failed).
    /// @return quoterHookData The constructed ALFHookData for nested execution.
    /// @dev Resolve an indicative quote for a single target via the cheapest accurate path
    ///      available. Waterfall, in order of preference:
    ///
    ///        1. **IALFHook** (ERC-165 detected) — full liveness/gas-budget/attestation path.
    ///        2. **SwapSimulator** (vanilla CFMM or light hook) — tick-walks the pool's real
    ///           state via `extsload`. Exact when nothing outside the AMM curve modifies the
    ///           swap result. See `_isSimulatorSafe` for the gate.
    ///        3. **IIndicativeQuote** (ERC-165 detected) — cheap view-style quote exposed by
    ///           hooks that override the AMM curve (e.g. PropAMM aggregators).
    ///        4. **Reverting self-swap** — signaled by returning `q == 0` here; the actual swap
    ///           attempt happens in `_queryTargetBySwap`.
    ///
    ///      The caller (`_queryTargetBySwap`) uses tiers 1–3's result directly when non-zero
    ///      and only falls back to tier 4 when this returns `(0, "")`.
    function _queryTargetView(
        TargetedQuoter memory target,
        bytes memory attestationData,
        bool zeroForOne,
        int256 amountSpecified
    ) internal view returns (uint256 q, bytes memory quoterHookData) {
        address hook = address(target.poolKey.hooks);

        // Tier 1: IALFHook
        if (_supportsInterface(hook, type(IALFHook).interfaceId)) {
            return _queryViaIALFHook(hook, target.poolKey, attestationData, zeroForOne, amountSpecified);
        }

        // Tier 2: simulator-safe pool (vanilla CFMM or hook that doesn't override the curve)
        if (_isSimulatorSafe(target.poolKey)) {
            uint24 lpFee = LPFeeLibrary.isDynamicFee(target.poolKey.fee) ? 0 : target.poolKey.fee;
            uint256 indicative = SwapSimulator.simulateSwap(
                poolManager, target.poolKey.toId(), zeroForOne, amountSpecified, lpFee, target.poolKey.tickSpacing
            );
            return (indicative, "");
        }

        // Tier 3: IIndicativeQuote (aggregator hooks, PropAMMs, etc.).
        // `indicativeQuote` is declared non-view in the interface so that hooks whose underlying
        // resolvers happen to lack the `view` keyword can satisfy it. We invoke through
        // `staticcall` so the EVM rejects any actual state write at runtime — read-only
        // implementations succeed; any implementation that tries to mutate state reverts and we
        // treat that as "no quote available".
        if (_supportsInterface(hook, type(IIndicativeQuote).interfaceId)) {
            (bool ok, bytes memory ret) = hook.staticcall(
                abi.encodeCall(IIndicativeQuote.indicativeQuote, (target.poolKey, zeroForOne, amountSpecified))
            );
            if (ok && ret.length >= 32) {
                return (abi.decode(ret, (uint256)), "");
            }
        }

        // Tier 4 signal: return (0, "") so `_queryTargetBySwap` runs the reverting self-swap.
        return (0, "");
    }

    /// @dev Existing IALFHook quote path, extracted out of `_queryTargetView`.
    function _queryViaIALFHook(
        address hook,
        PoolKey memory poolKey,
        bytes memory attestationData,
        bool zeroForOne,
        int256 amountSpecified
    ) internal view returns (uint256 q, bytes memory quoterHookData) {
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
        quoterHookData = abi.encode(ALFHookData({attestationData: attestationData}));

        try IALFHook(hook).getIndicativeQuote{gas: gasLimit}(poolKey, zeroForOne, amountSpecified, quoterHookData)
        returns (uint256 indicative) {
            q = indicative;
        } catch {}
    }

    /// @dev Defensive ERC-165 probe. Returns `false` if the target is not ERC-165 compliant, the
    ///      call reverts for any reason, or the target returns `false`.
    function _supportsInterface(address hook, bytes4 interfaceId) internal view returns (bool ok) {
        try IERC165(hook).supportsInterface(interfaceId) returns (bool s) {
            ok = s;
        } catch {}
    }

    /// @dev True when `SwapSimulator.simulateSwap` will produce an exact quote for the pool:
    ///      no `beforeSwap`-returns-delta hook, no `afterSwap`-returns-delta hook, and no
    ///      hook-driven dynamic LP fee. Vanilla v4 pools (no hook) qualify trivially.
    ///      Pure function; reads only the address-encoded hook permission bits and the pool fee.
    function _isSimulatorSafe(PoolKey memory key) internal pure returns (bool) {
        if (address(key.hooks) == address(0)) return true;
        uint160 flags = uint160(address(key.hooks)) & Hooks.ALL_HOOK_MASK;
        if (flags & (Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) != 0) {
            return false;
        }
        if (LPFeeLibrary.isDynamicFee(key.fee) && (flags & Hooks.BEFORE_SWAP_FLAG) != 0) {
            return false;
        }
        return true;
    }

    /// @dev Resolve a per-target quote. First tries the cheap waterfall in `_queryTargetView`
    ///      (tiers 1–3); if every tier declines (`q == 0` after the view path), falls through to
    ///      the expensive but universal reverting-self-swap tier-4 fallback. Tier 4 supports
    ///      hooks that override the AMM and do not advertise any indicative interface (e.g.
    ///      SmartPoolHook predecessors, custom one-off integrations).
    function _queryTargetBySwap(
        TargetedQuoter memory target,
        bytes memory attestationData,
        bool zeroForOne,
        int256 amountSpecified
    ) internal returns (uint256 q, bytes memory quoterHookData) {
        // Skip targets whose hook is this contract — preventing the multiplexer from recursing into
        // itself (gas-DoS via nested MultiplexerHookData). Only the caller pays for the wasted gas,
        // but no useful execution is possible against the multiplexer's virtual pool.
        if (address(target.poolKey.hooks) == address(this)) return (0, "");

        (q, quoterHookData) = _queryTargetView(target, attestationData, zeroForOne, amountSpecified);

        // Tiers 1–3 produced a usable quote: trust it and skip the expensive reverting-swap.
        // The split-fill execution path runs the real swap anyway and reconciles deltas, so the
        // indicative is only used for sorting + tolerance baseline.
        if (q != 0) return (q, quoterHookData);

        // Tier 4: universal reverting-swap fallback. Only fires for hooks that override the AMM
        // AND don't expose IALFHook / IIndicativeQuote.
        try this.quoteTargetBySwap(target.poolKey, zeroForOne, amountSpecified, quoterHookData) returns (uint256) {
            // quoteTargetBySwap always reverts with QuoteSwap on success.
        } catch (bytes memory reason) {
            q = _parseQuoteOrZero(reason);
        }
    }

    function _parseQuoteOrZero(bytes memory reason) internal pure returns (uint256 quoteAmount) {
        if (reason.length != 36) return 0;

        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
            quoteAmount := mload(add(reason, 0x24))
        }

        if (selector != QuoterRevert.QuoteSwap.selector) return 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          SPLIT FILL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Returns true if any target has a non-zero amountSpecified, indicating the router
    ///      has pre-planned the split and the multiplexer should execute in the given order.
    function _isPrePlanned(TargetedQuoter[] memory targets) internal pure returns (bool) {
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i].amountSpecified != 0) return true;
        }
        return false;
    }

    /// @dev Validate pre-planned per-target amounts against the outer swap.
    ///      - Every non-catch-all target's `amountSpecified` must share the outer sign
    ///        (exact-input → negative; exact-output → positive).
    ///      - Sum of `|amountSpecified|` over non-catch-all targets must be ≤ `|swapAmount|`.
    function _validatePrePlannedAmounts(MultiplexerHookData memory ahd, int256 swapAmount, bool exactInput)
        internal
        pure
    {
        // Compare against |swapAmount| using int256 arithmetic. swapAmount fits int256 by definition.
        int256 sumSigned;
        for (uint256 i = 0; i < ahd.targets.length; i++) {
            int256 a = ahd.targets[i].amountSpecified;
            if (a == 0) continue; // catch-all leg
            if ((a < 0) != exactInput) revert TargetDirectionMismatch();
            sumSigned += a;
        }
        if (exactInput) {
            // Both negative: |sumSigned| > |swapAmount| ⇔ sumSigned < swapAmount
            if (sumSigned < swapAmount) revert TargetsOverAllocated();
        } else {
            if (sumSigned > swapAmount) revert TargetsOverAllocated();
        }
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
    /// @param ahd         Decoded MultiplexerHookData.
    /// @param zeroForOne  The swap direction.
    /// @param swapAmount  The total swap amount.
    /// @return totalDelta     Accumulated BalanceDelta across all fills.
    /// @return primaryQuoter  The first target's hook address.
    /// @return bestQuote      Best individual indicative (0 if tolerance is disabled).
    function _executePrePlanned(MultiplexerHookData memory ahd, bool zeroForOne, int256 swapAmount)
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
    function _queryBestIndicative(MultiplexerHookData memory ahd, bool zeroForOne, int256 swapAmount)
        internal
        returns (uint256 best)
    {
        bool exactInput = swapAmount < 0;
        for (uint256 i = 0; i < ahd.targets.length; i++) {
            (uint256 q,) = _queryTargetBySwap(ahd.targets[i], ahd.attestationData, zeroForOne, swapAmount);
            if (q == 0) continue;
            if (best == 0 || (exactInput ? q > best : q < best)) {
                best = q;
            }
        }
    }

    /// @dev Execute targets in the given order with their pre-planned amounts.
    ///      Separated from _executePrePlanned to manage stack depth.
    /// @dev Validates per-target `amountSpecified` against the outer swap before executing:
    ///      every non-zero (non-catch-all) target must share the outer swap's sign convention,
    ///      and the sum of pre-planned magnitudes must not exceed `|swapAmount|`. Without these
    ///      checks, an over-allocated leg flips the `remaining` tracker's sign and produces a
    ///      catch-all swap in the wrong direction.
    function _runPrePlannedFills(MultiplexerHookData memory ahd, bool zeroForOne, int256 swapAmount)
        internal
        returns (BalanceDelta totalDelta)
    {
        int256 remaining = swapAmount;
        bool exactInput = swapAmount < 0;
        uint160 noLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // Validate target amount signs and aggregate magnitude vs swapAmount.
        _validatePrePlannedAmounts(ahd, swapAmount, exactInput);

        for (uint256 i = 0; i < ahd.targets.length && remaining != 0; i++) {
            // Skip targets pointing back at this multiplexer to prevent recursion.
            if (address(ahd.targets[i].poolKey.hooks) == address(this)) continue;

            bytes memory quoterHookData = abi.encode(ALFHookData({attestationData: ahd.attestationData}));

            // Pick the per-target amount, then clamp against `remaining`. The clamp is the
            // load-bearing protection against catch-all-not-last over-fills: if a catch-all
            // leg only partially filled, `remaining` already reflects the residual, and a
            // subsequent sized leg with `amountSpecified > remaining` (or with the wrong
            // sign relative to the residual after a partial fill) must be capped — otherwise
            // the aggregate `totalDelta` exceeds the swapper's stated swap amount.
            int256 thisAmount = ahd.targets[i].amountSpecified != 0 ? ahd.targets[i].amountSpecified : remaining;
            if (exactInput) {
                // Both negative; "smaller magnitude" = "less negative" = "greater than".
                if (thisAmount < remaining) thisAmount = remaining;
            } else {
                // Both positive; "smaller magnitude" = "less than".
                if (thisAmount > remaining) thisAmount = remaining;
            }
            if (thisAmount == 0) continue;

            // Wrapped in try/catch so a single failing target does not abort the entire
            // pre-planned multiplexer — soft-fail per target, mirroring the autonomous-mode contract.
            try poolManager.swap(
                ahd.targets[i].poolKey,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: thisAmount, sqrtPriceLimitX96: noLimit}),
                quoterHookData
            ) returns (
                BalanceDelta delta
            ) {
                int128 filled = exactInput
                    ? (zeroForOne ? delta.amount0() : delta.amount1())
                    : (zeroForOne ? delta.amount1() : delta.amount0());
                remaining -= int256(filled);
                totalDelta = totalDelta + delta;

                emit FillExecuted(address(ahd.targets[i].poolKey.hooks), delta.amount0(), delta.amount1());
            } catch {
                emit FillFailed(address(ahd.targets[i].poolKey.hooks));
            }
        }

        if (!exactInput && remaining > 0) revert InsufficientLiquidity();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                    AUTONOMOUS SPLIT FILL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Phase 1 of autonomous split fill: build and sort the candidate array.
    ///
    ///      For each target in the MultiplexerHookData:
    ///        - Simulate the quoter's real swap path for an indicative quote
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
    /// @param ahd        Decoded MultiplexerHookData.
    /// @return candidates    Array of valid candidates, sorted best-first.
    /// @return count         Number of valid candidates (may be < candidates.length).
    /// @return bestIndividual The best individual indicative quote (tolerance baseline).
    function _prepareCandidates(bool zeroForOne, int256 swapAmount, MultiplexerHookData memory ahd)
        internal
        returns (FillCandidate[] memory candidates, uint256 count, uint256 bestIndividual)
    {
        bool isExactInput = swapAmount < 0;
        candidates = new FillCandidate[](ahd.targets.length);

        for (uint256 i = 0; i < ahd.targets.length; i++) {
            (uint256 q, bytes memory quoterHookData) =
                _queryTargetBySwap(ahd.targets[i], ahd.attestationData, zeroForOne, swapAmount);
            if (q == 0) continue;

            // Read the quoter's current pool price for price limit computation during fills.
            // This is a snapshot — the price won't change before we fill this candidate because
            // each pool is filled at most once during the split fill.
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(ahd.targets[i].poolKey.toId());

            candidates[count] = FillCandidate({
                poolKey: ahd.targets[i].poolKey, hookData: quoterHookData, sqrtPriceX96: sqrtPriceX96, indicative: q
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
                bool validLimit =
                    zeroForOne ? nextPrice < candidates[i].sqrtPriceX96 : nextPrice > candidates[i].sqrtPriceX96;
                limit =
                    validLimit ? nextPrice : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            } else {
                // Last candidate: no limit, fill as much as possible.
                limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            }

            // Execute the nested swap on this candidate's pool. Wrapped in try/catch so a single
            // failing target (vault DoS, malicious hook, etc.) is soft-skipped and the multiplexer
            // continues with the next candidate — matches the indicative-phase soft-fail
            // semantics in INV-MUX-3 instead of leaving fill-phase as a hard-fail asymmetry.
            try poolManager.swap(
                candidates[i].poolKey,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: remaining, sqrtPriceLimitX96: limit}),
                candidates[i].hookData
            ) returns (
                BalanceDelta delta
            ) {
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
            } catch {
                // Soft-fail: the failing candidate's transient state (hook state, PM deltas,
                // ERC-20 transfers, vault calls) is rolled back by EVM revert semantics.
                // remaining/totalDelta are unchanged; the next candidate inherits the original budget.
                emit FillFailed(address(candidates[i].poolKey.hooks));
            }
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
    ///      that offsets the virtual pool's swap. The multiplexer charges no fee of its
    ///      own — protocol fees flow through the candidates' nested v4 swaps natively.
    function _toBeforeSwapDelta(BalanceDelta delta, SwapParams calldata params)
        internal
        pure
        returns (BeforeSwapDelta)
    {
        int128 specified;
        int128 unspecified;

        if ((params.amountSpecified < 0) == params.zeroForOne) {
            specified = -delta.amount0();
            unspecified = -delta.amount1();
        } else {
            specified = -delta.amount1();
            unspecified = -delta.amount0();
        }

        return toBeforeSwapDelta(specified, unspecified);
    }
}
