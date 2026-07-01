# ALFMultiplexer
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/ALFMultiplexer.sol)

**Inherits:**
[BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md)

**Title:**
ALFMultiplexer

**Author:**
Uniswap Labs

Stateless atomic multiplexer deployed on a virtual (zero-liquidity) pool.
The multiplexer provides onchain competitive execution across an arbitrary mix of v4
pools: ALF-native quoter hooks (with the rich liveness / gas-budget / attestation
surface), vanilla CFMM pools, and third-party hooks that override the AMM curve. It
receives a set of targeted candidate pools from the router via hookData, sizes each
via a tiered quote waterfall, and executes a **greedy split fill** that distributes
swap flow across candidates in order of indicative quality.
## Tiered Quote Waterfall
Per candidate, the multiplexer probes for indicative pricing in order of richness.
Tier selection is purely a property of the candidate's PoolKey (hook flags +
ERC-165 advertisement); the router doesn't need to know which tier will fire.
1. **IALFHook** (ERC-165 detected): the rich path: liveness check, gas budget,
attestation, and per-candidate ALFHookData.
2. **SwapSimulator**: for vanilla CFMM pools and hooks that don't override the
swap curve (no `beforeSwap` / `afterSwap` returns-delta flags, no dynamic-fee
hook with `BEFORE_SWAP_FLAG`). Walks the pool's real state via extsload;
exact in-frame.
3. **IIndicativeQuote** (ERC-165 detected): minimal view-style quote surface for
hooks that override the curve (PropAMM hooks, aggregator hooks). Invoked via
low-level `staticcall` so non-`view` implementations can satisfy the interface,
but state writes revert.
4. **Reverting self-swap**: universal fallback for opaque hooks; only reached
from the execution path (view-side `quote()` returns no quote for these).
## Execution Model: Greedy Split Fill
Rather than picking a single winner, the multiplexer fills candidates sequentially from
best to worst indicative. Each candidate receives the full remaining swap amount with
a `sqrtPriceLimitX96` derived from the next candidate's current pool price. This
causes the v4 swap loop to terminate when the current candidate's marginal price
worsens to the next candidate's entry level, at which point remaining flow cascades
to the next candidate. The result is an approximately optimal split that:
- Fills the best-priced quoter first until price impact equalizes with the next
- Naturally handles quoters with different fee overrides and liquidity depths
- Degenerates to single-quoter execution when only one target is provided
- Works identically for exact-input and exact-output swaps
## Delta Forwarding
The multiplexer's virtual pool has zero liquidity; all execution happens via nested
`poolManager.swap()` calls on the candidates' real pools. The accumulated BalanceDelta
from all fills is negated into a `BeforeSwapDelta` that offsets the virtual pool's
swap, ensuring the multiplexer's net position is zero. The outer caller receives
the aggregate execution as their swap result.
## Protocol Fees
The multiplexer does not charge a protocol fee on its own virtual pool. v4 charges
the protocol fee natively on each nested candidate swap (against the candidate's
own pool), so layering an additional multiplexer-level fee would double-charge
users. Operators who want to collect fees through this routing path SHOULD
configure them on the underlying candidate pools.
## Tolerance Enforcement
Callers may set `strictTolerancePips` in MultiplexerHookData to revert if aggregate
execution falls below the best individual indicative by more than the specified
tolerance. This is a downside-only check: split fill producing more output than
the best individual indicative (the expected case) does not trigger a revert.
The baseline is the best pre-execution indicative across the targets, and it is not
re-derived after execution. A tier-1 indicative can be a constant-liquidity upper
bound that overstates output for swaps large enough to exhaust a quoter's depth
(e.g. a DualPool extrapolating its in-range buckets to the price extreme), so each
candidate's contribution to the baseline is first bounded by its declared effective
output liquidity (`getEffectiveLiquidity`); see `_baselineContribution`. Without
that bound a large swap against a deep-looking but shallow quoter would set an
unreachable threshold and trip the check on a fair fill. The bound applies only to
quoters that expose reserves (IALFHook); tier-2 simulator quotes are already exact
against real pool state, and tier-3/4 opaque quoters cannot be bounded (the
trusted-targets note below covers them). It is computed only when strict tolerance
is enabled.
A candidate that wins quoting but then contributes
nothing (it reverts and is soft-skipped (see Greedy Split Fill), or fills less than
it quoted) drops aggregate execution below that baseline and can trip the tolerance
revert even when the other candidates filled acceptably. This is intentional and
fail-safe (the check is downside-only, so the worst outcome is a revert, never a
bad fill), but it means a flaky or adversarial candidate in the target set can force
a revert ("quote-baiting") for a caller who enabled strict tolerance. Enable strict
tolerance only over trusted targets; otherwise bound slippage with a router-side
minimum-output / maximum-input check, which measures the actual aggregate execution
rather than a per-candidate pre-execution baseline. Hard-failing the
baseline-setting candidate instead of soft-skipping it would not help: its revert
would still abort the swap, and would break soft-fail resilience for the common
(non-strict) path, so the soft-skip is kept.
## Slippage Control: the outer `sqrtPriceLimitX96` is not enforced
The `sqrtPriceLimitX96` a caller passes on the outer swap to the multiplexer pool has
no effect on execution. The real swaps run as nested `poolManager.swap` calls inside
`_beforeSwap`, and those derive their own per-candidate price limits; the outer limit
is never propagated to them. The multiplexer then returns a `BeforeSwapDelta` that
offsets the outer swap, so the virtual pool itself performs no price-bounded
execution either. Callers MUST bound slippage via `strictTolerancePips` and/or a
minimum-output (or maximum-input) check in their own router. Treating the outer
`sqrtPriceLimitX96` as an onchain price bound (as one would for an ordinary v4 pool)
provides no protection here.
## Call Flow
```
Router → poolManager.swap(multiplexerPool, hookData=[targets])
→ ALFMultiplexer._beforeSwap()
→ _prepareCandidates(): waterfall-quote each target, sort by indicative
→ _executeFills(): for each candidate (best to worst):
→ poolManager.swap(candidate.pool, remaining, sqrtPriceLimit=next.price)
→ CandidateHook._beforeSwap() [if any: curve update, fee override]
← BalanceDelta
← accumulate delta, update remaining
← (totalDelta, primaryCandidate, bestQuote)
← BeforeSwapDelta (negated totalDelta)
← BalanceDelta (aggregate result for the swapper)
```
This nested-swap pattern is explicitly supported by v4's unlock model. All deltas
accumulate in transient storage and must net to zero before the unlock completes.

Callers MUST encode hookData as `abi.encode(MultiplexerHookData(...))` with a non-empty
`targets` array. Each target specifies a candidate pool's PoolKey. The shared
attestation payload is only forwarded to tier-1 (IALFHook) candidates as part of
the per-candidate ALFHookData the multiplexer constructs for them; tier-2/3/4
candidates receive empty hookData and any required hook input must be encoded into
the candidate's own pool design.

**Note:**
security-contact: security@uniswap.org


## Constants
### PIPS_DENOMINATOR
Parts-per-million denominator that gives `strictTolerancePips` its unit. Aggregate
execution fails the tolerance when `deviation * PIPS_DENOMINATOR > baseline * pips`.


```solidity
uint256 private constant PIPS_DENOMINATOR = 1_000_000
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager) BaseHook(_poolManager);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolManager`|`IPoolManager`|The Uniswap v4 PoolManager.|


### getHookPermissions

The multiplexer needs:
- `beforeAddLiquidity`: to block LP on the virtual pool (it must remain empty)
- `beforeDonate`: to block donations to the virtual pool (no LP can ever
claim them, so they would be permanently locked in PM accounting)
- `beforeSwap`: core multiplexer + split fill logic
- `beforeSwapReturnDelta`: to forward the aggregate nested delta to the outer swap


```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory);
```

### quote

Simulate the multiplexer without executing. Returns the single best quoter
and their indicative quote.

Intended for offchain routers to pre-identify the best candidate. The router
can then either:
(a) Send a single-target hookData for gas-efficient single-quoter execution, or
(b) Send multiple targets for the full split fill.
Note: this returns the best *single* quoter, not a split fill simulation.


```solidity
function quote(bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
    external
    view
    returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`zeroForOne`|`bool`|     The swap direction.|
|`amountSpecified`|`int256`|The swap amount (negative = exact input).|
|`hookData`|`bytes`|       ABI-encoded MultiplexerHookData with targets.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`winnerPoolKey`|`PoolKey`| The best quoter's pool key.|
|`winner`|`address`|        The best quoter's hook address.|
|`bestQuote`|`uint256`|     The best indicative (output for exact-in, input for exact-out).|
|`winnerHookData`|`bytes`|The constructed ALFHookData to pass in nested execution.|


### quoteTargetBySwap

External self-call target used to quote a candidate through the real v4 swap path.
The outer caller catches the deliberate `QuoteSwap` revert. Reverting here rolls
back the simulated candidate swap, including hook state, PoolManager state, ERC-20
transfers, vault calls, and transient deltas. Reverts with [NotSelf](/src/alf/ALFMultiplexer.sol/contract.ALFMultiplexer.md#notself) if invoked by
any caller other than this contract.

Precondition: `amountSpecified != 0`. Reachable only via the contract's own self-call;
zero-amount targets are filtered out upstream before this is invoked.


```solidity
function quoteTargetBySwap(
    PoolKey calldata poolKey,
    bool zeroForOne,
    int256 amountSpecified,
    bytes calldata hookData
) external returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|       The candidate quoter's pool key.|
|`zeroForOne`|`bool`|    The swap direction.|
|`amountSpecified`|`int256`|The swap amount (negative = exact input, positive = exact output).|
|`hookData`|`bytes`|       ABI-encoded ALFHookData for the candidate.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Always reverts before returning (function always reverts via {QuoterRevert.QuoteSwap}).|


### _beforeAddLiquidity

Blocks all liquidity additions. The multiplexer pool is a virtual dispatch mechanism
with zero liquidity; all real execution happens on candidates' pools.


```solidity
function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
    internal
    pure
    override
    returns (bytes4);
```

### _beforeDonate

Blocks all donations. The virtual pool has no LP positions and never will, so any
donation would be permanently locked in PoolManager accounting. Reverts unconditionally.


```solidity
function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
    internal
    pure
    override
    returns (bytes4);
```

### _beforeSwap

Core multiplexer entry point. Orchestrates:
1. Greedy split fill across sorted candidates
2. Protocol fee application (reads fee from slot0, takes to token jar)
3. Tolerance enforcement (downside-only)
4. Delta conversion for the virtual pool


```solidity
function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

### _multiplexAndSwap

Top-level multiplex-and-execute. Detects the execution mode from the hookData:
**Autonomous mode** (all targets have amountSpecified = 0):
Queries indicatives, sorts candidates by quote quality, and executes a greedy
split fill with price limits. Self-contained.
**Pre-planned mode** (any target has amountSpecified != 0):
Executes targets in the given order with their specified amounts. A target
with amountSpecified = 0 receives whatever remains. Skips sorting. Indicatives
are queried only if tolerance enforcement is enabled.


```solidity
function _multiplexAndSwap(PoolKey calldata key, bool zeroForOne, int256 swapAmount, bytes calldata hookData)
    internal
    returns (BalanceDelta totalDelta, address primaryQuoter, uint256 bestQuote, uint256 strictTolerancePips);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`||
|`zeroForOne`|`bool`|The swap direction.|
|`swapAmount`|`int256`|The swap amount (after protocol fee deduction for exact input).|
|`hookData`|`bytes`|  ABI-encoded MultiplexerHookData from the caller.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalDelta`|`BalanceDelta`|    Accumulated BalanceDelta across all fills.|
|`primaryQuoter`|`address`| The first quoter in fill order.|
|`bestQuote`|`uint256`|     The strict-tolerance baseline (best individual indicative, reserve- bounded when strict tolerance is enabled). 0 if skipped.|
|`strictTolerancePips`|`uint256`|The caller's strict-tolerance setting, decoded once here and returned so `_beforeSwap` does not re-decode the full hookData.|


### _multiplex

Single-winner selection used by the `quote()` view function. Iterates all targets
and returns the quoter with the best indicative quote. Does not execute any swaps.


```solidity
function _multiplex(bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
    internal
    view
    returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`zeroForOne`|`bool`|     The swap direction.|
|`amountSpecified`|`int256`|The swap amount (negative = exact input).|
|`hookData`|`bytes`|       ABI-encoded MultiplexerHookData.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`winnerPoolKey`|`PoolKey`| The best quoter's pool key.|
|`winner`|`address`|        The best quoter's hook address.|
|`bestQuote`|`uint256`|     The best indicative quote.|
|`winnerHookData`|`bytes`|The constructed ALFHookData for the winner.|


### _runTargeted

Iterate targets and return the single best quoter. Used by `quote()` for the
offchain view path. Each target is queried via `_queryTargetView`; the best
indicative wins (highest output for exact-in, lowest input for exact-out).


```solidity
function _runTargeted(
    bool zeroForOne,
    int256 amountSpecified,
    bytes memory attestationData,
    TargetedQuoter[] memory targets
)
    internal
    view
    returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData);
```

### _queryTargetView

Resolve an indicative quote for a single target via the cheapest accurate path
available. Performs liveness/gas-budget/attestation checks for tier-1 quoters and
returns (0, "") on any soft failure so the caller skips the quoter without reverting
the whole multiplexer. Constructs the per-quoter ALFHookData by pairing the shared
attestation data with the target's quoter-specific curve update data.
Waterfall, in order of preference:
1. **IALFHook** (ERC-165 detected): full liveness/gas-budget/attestation path.
2. **SwapSimulator** (vanilla CFMM or light hook): tick-walks the pool's real
state via `extsload`. Exact when nothing outside the AMM curve modifies the
swap result. See `_isSimulatorSafe` for the gate.
3. **IIndicativeQuote** (ERC-165 detected): cheap view-style quote exposed by
hooks that override the AMM curve (e.g. PropAMM aggregators).
4. **Reverting self-swap**: signaled by returning `q == 0` here; the actual swap
attempt happens in `_queryTargetBySwap`.
The caller (`_queryTargetBySwap`) uses tiers 1-3's result directly when non-zero
and only falls back to tier 4 when this returns `(0, "")`.


```solidity
function _queryTargetView(
    TargetedQuoter memory target,
    bytes memory attestationData,
    bool zeroForOne,
    int256 amountSpecified
) internal view returns (uint256 q, bytes memory quoterHookData);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`target`|`TargetedQuoter`|         The targeted quoter (pool key + curve update data).|
|`attestationData`|`bytes`|Shared attestation payload from the MultiplexerHookData.|
|`zeroForOne`|`bool`|     The swap direction.|
|`amountSpecified`|`int256`|The swap amount.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`q`|`uint256`|             The indicative quote (0 if invalid/failed).|
|`quoterHookData`|`bytes`|The constructed ALFHookData for nested execution.|


### _queryViaIALFHook

Existing IALFHook quote path, extracted out of `_queryTargetView`.


```solidity
function _queryViaIALFHook(
    address hook,
    PoolKey memory poolKey,
    bytes memory attestationData,
    bool zeroForOne,
    int256 amountSpecified
) internal view returns (uint256 q, bytes memory quoterHookData);
```

### _supportsInterface

Defensive ERC-165 probe. Returns `false` if the target has no code (vanilla v4 pool
with `hooks = address(0)`), the call reverts for any reason, the call returns
malformed data, or the target returns `false`. Uses low-level `staticcall` because
Solidity's typed-call wrapper raises a "call to non-contract address" check that
bypasses `try/catch` for hookless pools.


```solidity
function _supportsInterface(address hook, bytes4 interfaceId) internal view returns (bool ok);
```

### _baselineContribution

Reserve-aware strict-tolerance baseline contribution for one candidate. The strict
check (see `_beforeSwap`) compares actual aggregate execution against this baseline,
so the baseline must track DELIVERABLE output, not a quoter's ranking estimate. A
tier-1 (IALFHook) `getIndicativeQuote` can be a constant-liquidity upper bound that
overstates output for a swap large enough to exhaust the quoter's depth (e.g.
DualPool extrapolating its in-range buckets to the price extreme). Left unbounded,
such a quote inflates the threshold and trips the check on an otherwise-acceptable
fill. Bound the contribution by the candidate's declared effective output liquidity:
- exact input: cap the expected output at the deliverable output reserve;
- exact output: drop the candidate (return 0) when it cannot deliver the requested
output, so it cannot set an optimistically-low input baseline.
Candidates that are not IALFHook (tier-2 simulator quotes are already exact against
real pool state; tier-3 IIndicativeQuote and tier-4 opaque hooks expose no reserve
view) or that report zero reserves are returned unbounded — there is no cheaper
on-chain depth signal to bound them with. That residual is exactly why strict
tolerance is documented as safe only over trusted targets. Ranking/sort is unaffected;
this shapes only the strict-tolerance baseline, and runs only when strict tolerance is
enabled.


```solidity
function _baselineContribution(PoolKey memory poolKey, uint256 indicative, bool zeroForOne, int256 amountSpecified)
    internal
    view
    returns (uint256);
```

### _bestBoundedIndicative

Fold one candidate's already-queried indicative `q` into the running strict-tolerance
baseline. Bounds the contribution by deliverable reserves (`_baselineContribution`)
when `boundBaseline` is set, and keeps it if it improves on `currentBest`. Shared by
the autonomous (`_prepareCandidates`) and pre-planned (`_queryBestIndicative`)
baseline reductions so the logic lives in one place.
PRESERVED DIVERGENCE: pre-planned mode always bounds (its only caller is the strict
path), so it passes `boundBaseline = true`; autonomous mode bounds only when strict
tolerance is enabled, so it passes `boundBaseline = (strictTolerancePips > 0)`. When
`boundBaseline` is false the raw indicative is used as the contribution unchanged.
`currentBest == 0` is the unset sentinel (a real baseline is always > 0; a bounded
contribution of 0 means "drop from baseline"). For exact input the highest output
wins; for exact output the lowest input wins.


```solidity
function _bestBoundedIndicative(
    PoolKey memory poolKey,
    uint256 q,
    bool zeroForOne,
    int256 swapAmount,
    bool boundBaseline,
    uint256 currentBest
) internal view returns (uint256 best);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|     The candidate's pool key.|
|`q`|`uint256`|           The candidate's already-queried indicative quote (0 means no quote).|
|`zeroForOne`|`bool`|  The swap direction.|
|`swapAmount`|`int256`|  The swap amount (negative = exact input).|
|`boundBaseline`|`bool`|Whether to bound the contribution by deliverable reserves.|
|`currentBest`|`uint256`| The running best baseline (0 if unset).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`best`|`uint256`|       The updated running best baseline.|


### _isSimulatorSafe

True when `SwapSimulator.simulateSwap` will produce an exact-in-frame quote for the
pool. The hook (if any) must not:
- return a `beforeSwap` delta (could override curve output)
- return an `afterSwap` delta (could adjust post-swap delta)
- have `BEFORE_SWAP_FLAG` set AND be a dynamic-fee pool (would let the hook push an
`lpFeeOverride` per-swap that we can't observe from view context)
For dynamic-fee pools that DON'T have `BEFORE_SWAP_FLAG`, the fee applied at swap is
exactly `slot0.lpFee` (V4 doesn't allow per-swap overrides without that flag), so the
simulator IS exact in the same call frame. Cross-block freshness is a router-level
slippage concern, not ours. Vanilla v4 pools (no hook) qualify trivially.
Pure function; reads only the address-encoded hook permission bits and the pool fee.


```solidity
function _isSimulatorSafe(PoolKey memory key) internal pure returns (bool);
```

### _queryTargetBySwap

Resolve a per-target quote. First tries the cheap waterfall in `_queryTargetView`
(tiers 1-3); if every tier declines (`q == 0` after the view path), falls through to
the expensive but universal reverting-self-swap tier-4 fallback. Tier 4 supports
hooks that override the AMM and do not advertise any indicative interface (e.g.
DualPoolHook predecessors, custom one-off integrations).


```solidity
function _queryTargetBySwap(
    TargetedQuoter memory target,
    bytes memory attestationData,
    bool zeroForOne,
    int256 amountSpecified
) internal returns (uint256 q, bytes memory quoterHookData);
```

### _parseQuoteOrZero

Local QuoteSwap parser, kept instead of `QuoterRevert.parseQuoteAmount`: that helper
REVERTS (`UnexpectedRevertBytes`) on a non-`QuoteSwap` selector, but the tier-4
fallback must SOFT-FAIL — a candidate self-swap that reverts with any other error has
to yield 0 here so the quoter is skipped, not abort the whole multiplexer. This
version also length-gates the reason to the exact `selector + uint256` encoding (36
bytes) before reading it.


```solidity
function _parseQuoteOrZero(bytes memory reason) internal pure returns (uint256 quoteAmount);
```

### _filledComponent

The "filled" component of a candidate's swap delta, used to decrement `remaining`.
exact input:  filled = input consumed (negative): `remaining -= negative` → less negative
exact output: filled = output received (positive): `remaining -= positive` → less positive
Both converge `remaining` toward zero. Written identically in both fill loops.


```solidity
function _filledComponent(BalanceDelta delta, bool zeroForOne, bool exactInput) internal pure returns (int128);
```

### _fillCandidate

Execute a single candidate fill: the nested `poolManager.swap` wrapped in try/catch,
followed by extraction of the filled component and the per-fill telemetry emit.
Shared by both the autonomous (`_executeFills`) and pre-planned (`_runPrePlannedFills`)
loops, which differ only in how they derive `amount` and `limit`.
SOFT-FAIL: a reverting candidate (vault DoS, malicious hook, etc.) is caught, its
transient state (hook state, PM deltas, ERC-20 transfers, vault calls) rolled back by
EVM revert semantics, `FillFailed` emitted, and `(0, ZERO_DELTA, false)` returned so
the caller leaves `remaining`/`totalDelta` unchanged and the next candidate inherits
the original budget.


```solidity
function _fillCandidate(
    PoolKey memory poolKey,
    bytes memory hookData,
    bool zeroForOne,
    bool exactInput,
    int256 amount,
    uint160 limit
) internal returns (int128 filled, BalanceDelta delta, bool ok);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|   The candidate's pool key.|
|`hookData`|`bytes`|  hookData forwarded to the candidate's swap.|
|`zeroForOne`|`bool`|The swap direction.|
|`exactInput`|`bool`|Whether the outer swap is exact input.|
|`amount`|`int256`|    The amount to request from this candidate (already clamped by the caller).|
|`limit`|`uint160`|     The `sqrtPriceLimitX96` for this candidate's swap.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`filled`|`int128`|   The filled component (see `_filledComponent`); 0 on soft-fail.|
|`delta`|`BalanceDelta`|    The candidate's swap delta; ZERO on soft-fail.|
|`ok`|`bool`|       True when the swap succeeded; false on soft-fail.|


### _isPrePlanned

Returns true if any target has a non-zero amountSpecified, indicating the router
has pre-planned the split and the multiplexer should execute in the given order.


```solidity
function _isPrePlanned(TargetedQuoter[] memory targets) internal pure returns (bool);
```

### _validatePrePlannedAmounts

Validate pre-planned per-target amounts against the outer swap.
- Every non-catch-all target's `amountSpecified` must share the outer sign
(exact-input → negative; exact-output → positive).
- Sum of `|amountSpecified|` over non-catch-all targets must be ≤ `|swapAmount|`.


```solidity
function _validatePrePlannedAmounts(MultiplexerHookData memory ahd, int256 swapAmount, bool exactInput)
    internal
    pure;
```

### _executePrePlanned

Pre-planned execution: router has determined the optimal fill order and per-quoter
amounts. Execute targets in the given order with their specified amounts.
A target with amountSpecified = 0 acts as a "fill remaining" catch-all, receiving
whatever input/output is left after prior fills. Typically the last target.
Skips indicative queries and sorting for gas efficiency. If tolerance checking is
enabled (strictTolerancePips > 0), indicatives are queried on-demand for the
tolerance baseline.


```solidity
function _executePrePlanned(MultiplexerHookData memory ahd, bool zeroForOne, int256 swapAmount)
    internal
    returns (BalanceDelta totalDelta, address primaryQuoter, uint256 bestQuote);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`ahd`|`MultiplexerHookData`|        Decoded MultiplexerHookData.|
|`zeroForOne`|`bool`| The swap direction.|
|`swapAmount`|`int256`| The total swap amount.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalDelta`|`BalanceDelta`|    Accumulated BalanceDelta across all fills.|
|`primaryQuoter`|`address`| The first target's hook address.|
|`bestQuote`|`uint256`|     Best individual indicative (0 if tolerance is disabled).|


### _queryBestIndicative

Query all targets for indicatives and return the best one. Used by pre-planned mode
only when tolerance enforcement is enabled, so it ALWAYS bounds each contribution by
deliverable reserves (`boundBaseline = true`): an over-optimistic ranking quote must
not inflate the threshold. Shares the per-candidate reduction with the autonomous
baseline via `_bestBoundedIndicative`.


```solidity
function _queryBestIndicative(MultiplexerHookData memory ahd, bool zeroForOne, int256 swapAmount)
    internal
    returns (uint256 best);
```

### _runPrePlannedFills

Execute targets in the given order with their pre-planned amounts.
Separated from _executePrePlanned to manage stack depth.

Validates per-target `amountSpecified` against the outer swap before executing:
every non-zero (non-catch-all) target must share the outer swap's sign convention,
and the sum of pre-planned magnitudes must not exceed `|swapAmount|`. Without these
checks, an over-allocated leg flips the `remaining` tracker's sign and produces a
catch-all swap in the wrong direction.


```solidity
function _runPrePlannedFills(MultiplexerHookData memory ahd, bool zeroForOne, int256 swapAmount)
    internal
    returns (BalanceDelta totalDelta);
```

### _prepareCandidates

Phase 1 of autonomous split fill: build and sort the candidate array.
For each target in the MultiplexerHookData:
- Simulate the quoter's real swap path for an indicative quote
- Read the quoter's pool sqrtPriceX96 (for price limit computation)
- If valid (non-zero indicative), add to the candidates array
After collection, candidates are sorted by indicative quality using insertion
sort. The indicative is the best available signal for fill ordering because it
captures the combined effect of the quoter's fee override, liquidity depth, and
price impact in a single number. The sqrtPriceX96 is retained for price limit
computation during execution.
Insertion sort is O(n²) but optimal for the expected candidate set size (3-5).
The router controls the target count and should keep it small to bound gas.


```solidity
function _prepareCandidates(bool zeroForOne, int256 swapAmount, MultiplexerHookData memory ahd)
    internal
    returns (FillCandidate[] memory candidates, uint256 count, uint256 bestIndividual);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`zeroForOne`|`bool`|The swap direction.|
|`swapAmount`|`int256`|The swap amount (after any fee deduction).|
|`ahd`|`MultiplexerHookData`|       Decoded MultiplexerHookData.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`candidates`|`FillCandidate[]`|   Array of valid candidates, sorted best-first.|
|`count`|`uint256`|        Number of valid candidates (may be < candidates.length).|
|`bestIndividual`|`uint256`|The strict-tolerance baseline: the best individual indicative, reserve-bounded (see `_baselineContribution`) when strict tolerance is enabled; the raw best indicative otherwise (telemetry only).|


### _executeFills

Phase 2 of split fill: execute sequential swaps across sorted candidates.
For each candidate (best indicative first):
1. Compute a sqrtPriceLimitX96 from the next candidate's pool price. This causes
the v4 swap loop to terminate when the current candidate's marginal price
worsens to the next candidate's entry level (the optimal crossover point).
2. Execute a nested poolManager.swap() with the full remaining amount and the
computed price limit. The swap fills as much as possible within the limit.
3. Extract the "filled" amount from the delta and update remaining.
4. Accumulate the delta into totalDelta using BalanceDelta addition.
The loop terminates when remaining reaches zero (fully filled) or all candidates
are exhausted.
## Price Limit Edge Case
When two candidates share the same sqrtPrice (common when pools are initialized at
the same tick), the next candidate's price can't serve as a valid limit because v4
requires `limit < currentPrice` (zeroForOne) or `limit > currentPrice` (oneForZero).
In this case, the limit falls through to the extreme (MIN/MAX), which means the
current candidate is fully drained before moving to the next. This is correct but
not optimal for the degenerate equal-price case, but acceptable since the sort by
indicative ensures the better quoter (by fee/liquidity) fills first regardless.
## Remaining Tracking
For exact input (amountSpecified < 0):
`remaining` starts negative. Each fill's consumed input (negative delta) is
subtracted, moving remaining toward zero.
For exact output (amountSpecified > 0):
`remaining` starts positive. Each fill's received output (positive delta) is
subtracted, moving remaining toward zero. If remaining > 0 after all candidates
are exhausted, the swap cannot be fully filled and the function reverts.


```solidity
function _executeFills(FillCandidate[] memory candidates, uint256 count, bool zeroForOne, int256 swapAmount)
    internal
    returns (BalanceDelta totalDelta);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`candidates`|`FillCandidate[]`|Sorted array of fill candidates (best first).|
|`count`|`uint256`|     Number of valid candidates in the array.|
|`zeroForOne`|`bool`|The swap direction.|
|`swapAmount`|`int256`|The total swap amount to fill.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`totalDelta`|`BalanceDelta`|The accumulated BalanceDelta across all fills.|


### _worseQuote

Comparison function for insertion sort. Returns true if indicative `a` is worse
than `b` for the given swap type, meaning `b` should be sorted before `a`.
exact input:  higher output = better, so a < b means a is worse
exact output: lower input   = better, so a > b means a is worse


```solidity
function _worseQuote(uint256 a, uint256 b, bool isExactInput) internal pure returns (bool);
```

### _extractOutput

Extract the "output" amount from a BalanceDelta for tolerance comparison.


```solidity
function _extractOutput(BalanceDelta delta, SwapParams calldata params) internal pure returns (uint256);
```

### _toBeforeSwapDelta

Convert the accumulated BalanceDelta from nested fills into a BeforeSwapDelta
that offsets the virtual pool's swap. The multiplexer charges no fee of its
own; protocol fees flow through the candidates' nested v4 swaps natively.


```solidity
function _toBeforeSwapDelta(BalanceDelta delta, SwapParams calldata params)
    internal
    pure
    returns (BeforeSwapDelta);
```

## Events
### MultiplexerExecuted
Emitted once per multiplexer execution after all fills complete.


```solidity
event MultiplexerExecuted(
    address indexed primaryQuoter, bool zeroForOne, int256 amountSpecified, uint256 bestQuote
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`primaryQuoter`|`address`|The first quoter in the sorted fill order (best indicative).|
|`zeroForOne`|`bool`|   The swap direction.|
|`amountSpecified`|`int256`|The original swap amount (negative = exact input).|
|`bestQuote`|`uint256`|    The strict-tolerance baseline: the best individual indicative, reserve-bounded (see `_baselineContribution`) when strict tolerance is enabled; the raw best indicative otherwise.|

### FillExecuted
Emitted for each individual fill during a split fill execution.

Useful for tracking per-quoter contributions to the aggregate result.
`amount0` and `amount1` are from the multiplexer's perspective (same sign
convention as BalanceDelta).


```solidity
event FillExecuted(address indexed quoter, int128 amount0, int128 amount1);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`quoter`|`address`| The quoter hook address that was filled.|
|`amount0`|`int128`|Token0 delta for this fill (negative = input, positive = output).|
|`amount1`|`int128`|Token1 delta for this fill (negative = input, positive = output).|

### FillFailed
Emitted when a candidate fill reverts and is soft-skipped during a split fill.

The multiplexer continues with the next candidate. Routers can monitor this event
to deprioritize the offending quoter in their reputation model.


```solidity
event FillFailed(address indexed quoter);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`quoter`|`address`|The quoter hook address whose fill failed.|

## Errors
### NoValidQuotes
No targeted quoter returned a valid (non-zero) indicative quote.


```solidity
error NoValidQuotes();
```

### LiquidityNotAllowed
The multiplexer's virtual pool must not hold liquidity.


```solidity
error LiquidityNotAllowed();
```

### InsufficientLiquidity
Exact-output split fill: aggregate output across all candidates did not satisfy
the requested amount. The swap cannot be fully filled at acceptable prices.


```solidity
error InsufficientLiquidity();
```

### QuoteDeviation
Strict tolerance check failed. For exact input, effective output was below the
reserve-bounded baseline output by more than `strictTolerancePips`; for exact
output, effective input paid was above the reserve-bounded baseline input by
more than `strictTolerancePips`.


```solidity
error QuoteDeviation(uint256 indicative, uint256 executed);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`indicative`|`uint256`|The reserve-bounded baseline used for the tolerance check (output for exact input, input for exact output). See `_baselineContribution`.|
|`executed`|`uint256`|The effective executed amount compared to the baseline (output for exact input, input paid for exact output).|

### NotSelf
Quote helper may only be called through an external self-call.


```solidity
error NotSelf();
```

### TargetsRequired
hookData was empty or contained no targets. The multiplexer requires at least one
targeted quoter to execute.


```solidity
error TargetsRequired();
```

### MissingQuoteBaseline
`strictTolerancePips > 0` but no indicative baseline could be established (every
candidate's quote query failed). Strict tolerance has nothing to compare against,
so the swap is refused: the caller asked for a guarantee the multiplexer cannot make.


```solidity
error MissingQuoteBaseline();
```

### TargetDirectionMismatch
Pre-planned mode received a target whose `amountSpecified` sign does not match the
outer swap direction (e.g., exact-input outer with an exact-output target). Allowing
mismatched signs would make the catch-all leg take the opposite swap direction and
corrupt the aggregate accounting.


```solidity
error TargetDirectionMismatch();
```

### TargetsOverAllocated
Pre-planned mode received targets whose summed `|amountSpecified|` exceeds
`|swapAmount|`. Over-allocating across legs flips the `remaining` tracker's sign and
produces malformed downstream fills.


```solidity
error TargetsOverAllocated();
```

### TargetCurrencyMismatch
A target's pool trades a different currency pair than the multiplexer's virtual pool.
The virtual pool's `BeforeSwapDelta` can only offset deltas in its own
`currency0`/`currency1`, so a mismatched-pair fill would leave non-netting deltas and
revert the unlock with the opaque `CurrencyNotSettled`. Caught up front instead.


```solidity
error TargetCurrencyMismatch(uint256 index);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`index`|`uint256`|The index of the offending target in the `targets` array.|

### UnrepresentableDelta
An accumulated delta component equals `type(int128).min`, which `_toBeforeSwapDelta`
cannot negate (overflow in 0.8.x). Unreachable through normal fills (v4's checked
`toInt128` casts bound real deltas far below this) but surfaced as a clear error
rather than an opaque arithmetic panic if a crafted candidate delta ever hits it.


```solidity
error UnrepresentableDelta();
```

## Structs
### FillCandidate
Tracks a candidate pool during the split fill process. Built during
`_prepareCandidates`, sorted by indicative quality, and consumed sequentially by
`_executeFills`.


```solidity
struct FillCandidate {
    PoolKey poolKey;
    bytes hookData;
    uint160 sqrtPriceX96;
    uint256 indicative;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The candidate's pool key (hook address embedded in `poolKey.hooks`).|
|`hookData`|`bytes`|hookData forwarded to the candidate's swap. For tier-1 (IALFHook) candidates this is the per-candidate ALFHookData (attestation + curve update); for tier-2/3/4 candidates this is empty.|
|`sqrtPriceX96`|`uint160`|The candidate's pool price at query time, used for price limits.|
|`indicative`|`uint256`|Indicative quote for the full swap amount, used for sorting.|

