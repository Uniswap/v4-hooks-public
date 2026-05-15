# NativeBookHook Audit Notes

## Scope

`NativeBookHook` is a maker-facing quote-ladder hook backed by native Uniswap v4
liquidity. Makers post bounded bid and ask capacity into canonical bins around
the current pool tick. The hook owns the native v4 positions and tracks maker
ownership and deposited inventory in hook storage; swaps remain ordinary v4
swaps and do not require router-provided `hookData`.

## External Surface

- `initializePool`: owner-only pool initialization plus canonical bin config.
- `setPoolLive`: owner-only swap liveness control.
- `deposit` / `depositFor`: custody ERC-20 inventory for makers.
- `withdraw`: withdraw unused maker inventory.
- `inventoryBalance`: read a maker's withdrawable inventory.
- `replaceLadder`: maker directly replaces all active bins for a pool with an
  execution-time reference-tick bound.
- `replaceLadderWithSig`: relayer posts a full replacement with a maker EIP-712
  signature, nonce, deadline, and reference-tick bound.
- `cancelLadder`: maker directly removes all active bins for a pool.
- `cancelLadderWithSig`: relayer removes all maker bins with a maker EIP-712
  signature and nonce.
- `retirePosition`: public keeper path for a single expired or crossed bin.
- `retirePositions`: public keeper path for a bounded, skip-invalid batch.
- `claimFees`: public fee-claim path; proceeds are always credited to the recorded
  maker.
- `IALFHook` metadata: `isLive` and `maxGas` let ALF-aware callers recognize the
  hook as an ALF hook.
- `IALFHook` quote methods: `getIndicativeQuote` and `swapToPrice` simulate the
  native v4 tick-walking swap path, including the same bounded stale-bin
  retirement that `beforeSwap` applies before execution.
- Indicative quotes are gas bounded. The quoter returns zero if simulation
  crosses more than `MAX_QUOTE_TICK_STEPS` initialized tick steps, if a supplied
  price limit is invalid under v4 swap rules, or if an exact-output request
  cannot be fully satisfied.
- `IALFHook` reserve methods: `getReserves` and `getEffectiveLiquidity`
  intentionally return zero because this hook's executable liquidity is native
  v4 pool liquidity, not a separate off-pool ALF curve with a cheap pool-scoped
  reserve view.

## Core Invariants

- Only this hook can initialize configured pools; direct `PoolManager.initialize`
  calls are blocked by `beforeInitialize`.
- Native ETH pools are unsupported. Maker inventory custody is ERC-20 only.
- One-bin-wide native v4 liquidity ranges matching the configured book bin width
  are reserved for the hook. Passive LPs may still use broader ranges.
- A maker replacement is full-state, not incremental: old active bins are removed
  before new bins are posted. Direct replacements and cancellations consume the
  maker nonce to invalidate outstanding signed quote intents.
- Replacement inputs must not contain duplicate same-side offsets. Each active
  position id is tracked once in the maker and pool indexes.
- Replacement uses `expectedRefTick` plus `maxTickDeviation` to prevent signed or
  public mempool replacement from silently anchoring a ladder to a manipulated
  spot tick.
- Quote posting debits the maker's custodied inventory; cancellations,
  retirements, and fee claims credit custodied inventory back to the maker.
- Maker positions are tracked in both maker-level and pool-level indexes. Active
  position count and maker position count must move together on post, cancel,
  retirement, and replacement.
- Quote bins are one-shot in lifecycle terms: after expiry or crossing, anyone
  can retire the position and return proceeds to the maker. Expiry/crossing is a
  retirement condition, not a hard execution gate; native v4 liquidity can trade
  until it is actually retired.
- Relayed and direct replacement/cancellation consume the same global per-maker
  nonce stream, so signed updates are strictly ordered across both verbs and
  across pools.
- `claimFees` and retirement are public, but funds are always credited to the
  recorded maker's inventory.
- `beforeSwap` must not depend on router `hookData`. It only enforces pool
  liveness and opportunistically retires a bounded number of stale/crossed bins.
- The `IALFHook` quote surface must not overstate executable book liquidity. The
  quote path applies virtual liquidity removals for the same bounded set of
  expired/crossed bins that `beforeSwap` would retire before the real swap.

## Security Boundaries

- The hook does not implement a CLOB or matching engine. Price execution remains
  the native v4 swap path over native liquidity.
- The hook does not protect makers from stale quotes before their configured TTL
  or before crossing. Makers should use short TTLs and signed replacement/cancel
  flows for active quoting.
- The main hook is custodial. Makers must deposit inventory before quoting, and
  wallet withdrawals are explicit via `withdraw`.
- Fee-on-transfer tokens are not a primary target. Deposits and PoolManager
  positive deltas credit actual received amounts, but v4 settlement and
  PoolManager transfers still assume standard ERC-20 behavior.
- `maxRetirePerSwap` bounds both swap-time cleanup removals and inspected
  candidates. `retirePositions(maxRetire)` bounds keeper-paid removals. Stale
  positions can remain active until swaps or keepers retire them.
- `isLive()` is hook-level liveness for ALF discovery. Pool-level liveness is
  still `poolLive[poolId]` and is enforced during `beforeSwap`.
- ALF quotes are whole-pool native-v4 quotes. Routers that also route directly
  against the same v4 pool must deduplicate by pool id or use a NativeBook-aware
  adapter; this hook does not expose a separate book-only curve.
- `getReserves` and `getEffectiveLiquidity` intentionally return zero for this
  native-liquidity hook. They are not solvency or TVL views for custodied maker
  inventory.

## Event Model

The event surface is intended to let indexers reconstruct pool configuration,
maker ladder changes, position ids, relayed update context, fee claims, and
keeper retirement activity:

- `PoolCreated`
- `PoolLivenessUpdated`
- `InventoryDeposited`
- `InventoryWithdrawn`
- `LadderReplaced`
- `LadderCanceled`
- `BinPosted`
- `BinRetired`
- `FeesClaimed`
- `PositionsRetired`

`BinPosted` and `BinRetired` include `positionId` as an indexed topic so offchain
systems can track hook-owned native v4 positions without recomputing salts.

## Current Test Coverage

- Direct replacement, replacement over existing bins, zero-duplicate same-bin
  replacement, and multi-maker same-bin quoting.
- Maker inventory deposit, third-party `depositFor`, withdrawal, and
  insufficient-inventory reverts.
- Signed replacement success, replay rejection, expiry rejection, and wrong
  signer rejection, plus reference-tick slippage and delayed-expiry guards.
- Direct replacement/cancellation invalidation of older signed intents.
- Duplicate bid/ask offset rejection and zero `minBinLiquidity` rejection.
- Direct cancellation, signed cancellation, relayed cancel event context, replay
  rejection, expiry rejection, and wrong signer rejection.
- Generic router swaps with empty or arbitrary `hookData`.
- Pool liveness wrapped errors and reserved book-range wrapped errors.
- `IALFHook` interface conformance, exact-input/exact-output quote fidelity, and
  stale-bin retirement during indicative quoting.
- Expired and crossed retirement, keeper batches, fee claiming, and event
  regressions.
- A bounded fuzz property for canonical bin tracking after replacement.
- Gas snapshots for replacement, signed replacement, swap paths, batch
  retirement, and fee claim.

## Audit Focus Areas

- PoolManager unlock callback correctness and action decoding.
- Position tracking under replacement, cancellation, crossed retirement, and
  batched retirement.
- Signed verb nonce ordering across `replaceLadderWithSig` and
  `cancelLadderWithSig`.
- Delta settlement and maker payment behavior across ERC-20 edge cases.
- Custodied inventory solvency across post, replace, cancel, retire, claim, and
  withdraw flows.
- DoS bounds for maker bin counts, keeper batches, and opportunistic retirement.
- Economic behavior of stale quotes, partial fills, and native v4 fee accrual.

## Pashov Pipeline Findings

The internal Pashov-style review surfaced these production issues and leads:

- Fixed: duplicate same-side offsets could reuse one `positionId`, overwrite
  metadata, and orphan native v4 liquidity. The hook now rejects duplicate
  offsets and defensively rejects duplicate tracked position ids.
- Fixed: swap-time cleanup previously bounded removals but not candidates
  scanned. The hook now bounds inspected candidates by `maxRetirePerSwap`.
- Fixed: direct maker replacement/cancellation did not invalidate outstanding
  signed relayer intents. Direct quote mutations now consume the maker nonce.
- Fixed: replacement intent did not bind a reference tick. Direct and signed
  replacement now require `expectedRefTick` and `maxTickDeviation`.
- Fixed: signed replacement could be delayed until just before `deadline` and
  still receive a fresh full TTL. Signed replacement now requires
  `block.timestamp + ttl <= deadline`.
- Fixed: the ALF quote surface previously returned the unsupported value. It now
  simulates native v4 swap execution and excludes the same bounded set of
  retirable bins that `beforeSwap` removes before execution.
- Fixed: exact-output indicative quotes previously reported partial-fill input
  as if the full requested output were satisfiable. Exact-output quotes now
  return zero unless the full output amount can be simulated.
- Fixed: dynamic-fee NativeBook pools previously passed the dynamic-fee sentinel
  into quote math. The simulator now resolves the current stored PoolManager LP
  fee and mirrors v4 protocol-fee composition.
- Fixed: invalid price limits and 100% exact-output fee cases now fail closed to
  zero in quote simulation instead of producing impossible results or bubbling a
  math revert.
- Fixed: ALF quote simulation now has an initialized-tick step cap so a dense
  tick bitmap returns zero instead of exceeding the declared quote gas budget.
- Fixed: `retirePositions` now rejects candidate arrays longer than `maxRetire`,
  making keeper-paid scan work explicit.
- Fixed: swap-time hook retirement now enters an internal settlement guard so
  token callbacks cannot reenter public inventory or ladder mutation paths while
  balance-diff crediting is in progress.
- Hardened: PoolManager positive deltas now credit inventory by actual hook
  balance increase, not nominal delta.
- Hardened: `minBinLiquidity` must be nonzero.
- Accepted boundary: TTL/crossing is best-effort until a position is retired.
  Hard expiry would require path-aware stale-liquidity retirement or failing
  swaps when executable stale liquidity remains.
- Accepted boundary: the global maker nonce invalidates signed intents across
  pools. This is safer for stale-intent invalidation but less granular for
  multi-pool relayers.
- Accepted boundary: all exact one-bin passive LP ranges are reserved, not only
  the current active book bands.
- Accepted boundary: overlapping broader/narrower passive liquidity can share
  native v4 execution; the hook creates maker workflow, not CLOB priority.
- Accepted boundary: open-relay signatures do not bind `msg.sender`. A relayer
  can be front-run, but the maker-authorized state transition and nonce
  consumption are still enforced.

## Static Analysis Triage

A targeted Slither run against `src/alf/NativeBookHook.sol` did not complete
cleanly in this local environment because Slither failed to generate IR for
inherited OpenZeppelin `EIP712` internals. The detector output still surfaced
the expected hook-shape findings below:

- `calls-loop`: expected but bounded by `maxMakerBins`, `maxRetirePerSwap`, and
  caller-supplied `maxRetire`.
- `divide-before-multiply`: expected in `_referenceTick`; this is deliberate
  integer bin rounding.
- `timestamp`: expected for signature deadlines and quote expiry.
- `unused-return`: expected for PoolManager calls where the hook only needs the
  balance delta or callback side effect.
- `reentrancy-benign` / `reentrancy-events`: tied to trusted PoolManager
  initialization. Review this path during audit, but no untrusted callback is
  expected before liveness is set.
