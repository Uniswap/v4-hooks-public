# ALF: Composable Quoter Design Doc

---

# Introduction

The Composable ALF concept described here is a layered hook architecture that enables proprietary market makers to operate custom AMMs within the Uniswap v4 ecosystem. Each quoter deploys its own v4 hook with full hook lifecycle access, a shared `IALFHook` interface and abstract `BaseALFHook` standardize how the router and auction hook query indicative quotes, and the router drives intelligent dispatch through a statistical reputation model.

The proposal is largely motivated by the rapid growth of ALF volume on Base (from ~10% to ~40% of aggregator volume in ~2 months), coupled with our broader desire to enable more sophisticated proprietary trading strategies for LPs. On Base, ALF share of aggregator volume has grown from roughly 10-12% in late December/early January to approximately 40% and climbing. While aggregators are still a small percentage of total Base DEX volume (on the order of 5-6%), this trajectory represents a significant risk to Uniswap's market positioning on Base if we don't offer a competitive ALF product within the v4 ecosystem.

The core design is centered around router-driven discovery and dispatch with reputation-enforced quote fidelity. Competition between quoters is driven by the router's EV model, which tracks historical quote accuracy, fill rates, and win rates per quoter. The atomic auction hook is available for environments (e.g., mainnet) where on-chain fairness guarantees are required. The decision of whether to route directly or through the auction hook is a pure routing-level concern; quoters do not opt in or out. Hooks expose their own metadata via the `IALFHook` interface — no shared registry is required.

# Design Philosophy

The original ALF proposal concentrates registry management, competitive dispatch, fallback comparison, flow attestation, and liquidity provisioning into a single monolithic hook. This revised design decomposes those concerns into independent, composable layers that align more closely with v4's native primitives.

Rather than re-implementing core AMM logic modified for competitive quoting inside a hook, we push competition to the router layer and give each quoter the full hook lifecycle to work with. Cross-cutting concerns like flow attestation are exposed as virtual extension points on the shared `BaseALFHook` (default no-op), letting each maker decide how to verify attestation payloads against their own trust model — there is no shared registry contract. Hook metadata (indicative quotes, liveness, gas budgets, reserves, price-bounded simulation) is exposed directly by each hook via the `IALFHook` interface. This model scales to an arbitrary number of quoters, imposes minimal constraints on quoter architecture and complexity, and requires no coordination for introducing new quoter types.

The architecture is shaped by several key assumptions:

- **Quoter flexibility is the whole point.** The complexity of proprietary market making is such that no single interface or curve model could cover the range of optimizations makers need to compete effectively. Quoters need access to the full v4 hook lifecycle (e.g., `afterSwap` for post-trade analytics, dynamic fees, custom curve logic, arbitrary state management), not a tightly constrained quoting API.
- **Dispatch intelligence belongs in the router.** The router has access to historical data, statistical models, and per-quoter reputation tracking that cannot be efficiently replicated onchain. Putting dispatch logic inside a hook means calling every quoter exhaustively and picking the best, which is the least efficient selection strategy and doesn't scale as the quoter set grows.
- **Each component should have a small, independent audit surface.** The shared base contracts (`BaseALFHook`, `SpreadQuoterBase`, `PoolVault`, `SwapSimulator`, `ALFProtocolFees`) are thin and stateless beyond what curve-update bookkeeping and share math require. Quoter hooks are independently deployed and independently auditable. A bug in one quoter's pricing logic cannot corrupt another quoter's code or state.
- **v4's native pool composition is the right building block.** Each quoter gets its own pool. Competition happens across pools, either at the router level or onchain through the auction hook. This uses the platform as intended rather than reimplementing exchange infrastructure inside a single hook.

The result is a design where:

- Quoters have maximum flexibility over their own pricing and execution logic
- Adding a new quoter type never requires modifying shared contracts
- The audit surface for each component is small and independent
- The router controls dispatch strategy using a rich statistical model that cannot be replicated on-chain
- An optional atomic auction hook is available for environments where on-chain fairness guarantees are required

# Architecture Concept

There are four layers in this system:

| Layer | Component | Responsibility |
| --- | --- | --- |
| 0 | Shared Base Contracts | Standard interface (`IALFHook`), abstract base (`BaseALFHook`), spread-quoter scaffolding (`SpreadQuoterBase`), share-math base (`PoolVault`), tick-walking simulator (`SwapSimulator`), auction protocol-fee base (`ALFProtocolFees`). No standalone deployments — these are libraries and abstract contracts inherited by quoter and auction hooks. |
| 1a | Quoter Hooks | Individual v4 hooks per market maker. Full hook lifecycle, custom pricing, independent deployment. Each hook exposes its own metadata via `IALFHook`. |
| 1b | Auction Hook | Stateless onchain auction. Receives a targeted quoter set via `hookData`, queries indicative quotes, executes a greedy split fill across candidates (or a router-supplied pre-planned split), and applies the v4 protocol fee on the unspecified side. |
| 2 | Router | Primary dispatch. EV-based quoter selection, reputation model, quote fidelity tracking, fallback management. |

Information flows downward: the router queries quoter hooks directly (via `IALFHook`) and routes to the best pool. Quoter hooks are entirely self-contained — they consult no shared registry contract. The auction hook is a transparent intermediary; quoters see the same `beforeSwap` invocation regardless of whether the swap was initiated by the router directly or through the auction hook.

## **Layer 0: Shared Base Contracts**

These are abstract contracts and libraries inherited by quoter and auction hooks. None are deployed standalone.

### Self-Describing Hooks (`IALFHook`)

Each ALF hook exposes its own metadata directly via the `IALFHook` interface. There is no shared onchain registry — hooks are self-describing. The router discovers hooks through its own tracking and queries them directly.

The interface surfaces five view methods:

- `getIndicativeQuote(key, zeroForOne, amountSpecified, hookData)` — the indicative output (or required input for exact-output) for a given swap. The router and auction hook invoke this via `staticcall`.
- `swapToPrice(key, zeroForOne, amountSpecified, sqrtPriceLimitX96, hookData)` — price-bounded simulation. Used by the auction hook and router for split-fill planning.
- `isLive()` — quoter-reported liveness hint.
- `maxGas()` — declared gas budget for `getIndicativeQuote`. Callers cap their `staticcall` gas to this value.
- `getReserves(key)` and `getEffectiveLiquidity(key)` — true TVL and immediately swappable liquidity, including off-pool reserves (vault deposits, ERC-6909 claims).

`BaseALFHook` provides default implementations for all five (`isLive` is abstract; `getReserves`, `getEffectiveLiquidity`, and `swapToPrice` default to `(0, 0)`).

**Design Notes**

- **No coordination required:** Deploying a new hook doesn't require registering with any shared contract. The router discovers hooks and builds its candidate set independently.
- **Liveness:** Self-reported by the hook via `isLive()`. Routers treat this as a hint and validate against observed behavior.
- **Spam resistance:** Handled entirely at the router layer via the reputation model — there is no governance-gated allowlist.

### Attestation Extension Point

Attestation handling is a per-hook concern, not a shared registry concern. `BaseALFHook` decodes the standard `ALFHookData` envelope (`{attestationData, curveUpdateData}`) and exposes a virtual `_resolveAttestation(bytes attestationData)` that returns `(bool isAttested, address attester)`. The default returns `(false, address(0))`. Subclasses that want preferential pricing for attested flow override `_resolveAttestation` and verify the payload against their own signer (typically via the hook's existing EIP-712 infrastructure and `priceSigner`).

This pushes the attestation trust model into each maker's hook, which lets makers:

- Choose their own attester set without coordinating with governance.
- Bind attestation verification to the same EIP-712 domain they use for signed curve updates.
- Layer additional checks (e.g., `swapHash` binding, deadline enforcement) without subclassing a registry interface.

The router and frontends are still responsible for distributing attestation payloads alongside swaps; the hook just chooses how to interpret them.

### Signed Curve Updates

`BaseALFHook` implements one-curve-update-per-block enforcement generically: `_curveUpdateHash[poolId][block.number]` records the first curve hash seen in a block, and subsequent swaps in the same block must either submit the matching hash or pass through with no curve update. `SpreadQuoterBase` builds on this with EIP-712 verification of `(PricingState, PoolId, deadline)` against an owner-managed `priceSigner`, and only commits the new state on the first matching swap of the block.

## **Layer 1a: Quoter Hooks**

Each market maker deploys its own v4 hook controlling a pool for the pair it quotes on. The hook has full authority over pricing logic, state management, the complete hook lifecycle (`beforeSwap`, `afterSwap`, `beforeAddLiquidity`, etc.), liquidity model, and liveness reporting.

**Update Modes**

| Mode | Pricing Inputs | State Updates | Best For |
| --- | --- | --- | --- |
| Storage-based | Hook reads coefficients from its own storage | Maker writes via standalone transactions (keeper, oracle, manual, block builder) | Major pairs on cheap-gas chains where per-block updates are affordable, or curves robust to staleness |
| hookData-based | Caller submits signed parameters via `hookData` at swap time | Written to storage on first swap per block; subsequent swaps reuse cached params | Mainnet (expensive updates), lower-volume pairs, long-tail tokens, makers needing sub-block pricing freshness |

`SpreadQuoterBase` supports both modes simultaneously: it reads owner-committed pricing from storage and overlays signed curve updates from `hookData` on top. The router tracks quoter behavior patterns (update frequency, parameter staleness) as part of its reputation model.

The one-curve-update-per-block invariant is implemented generically in `BaseALFHook._checkAndMarkCurveUpdate` (see Layer 0).

Extending `BaseALFHook` (or one of its subclasses) gives quoters a few things for free: standard `ALFHookData` decoding, a virtual attestation extension point (default no-op — subclasses verify against their own signer), one-curve-per-block enforcement for any signed curve updates, default implementations of the `IALFHook` view methods, and `DeltaResolver` settlement helpers. Subclasses still control their curve and all parameters, how they respond to attested/unattested flow, inventory/risk management, whether to support hookData-based curve updates at all, and any other hook lifecycle behavior. Extending the base is encouraged but not required.

**Reference implementations in this branch:**

- `SimpleSpreadQuoterHook` — minimal `SpreadQuoterBase` subclass with owner-restricted LP and single-tick concentration. Used as the baseline strategy and as a fixture for the auction hook tests.
- `SmartPoolHook` — multi-range JIT spread quoter with ERC4626 vault rehypothecation. Idle inventory earns yield in vaults between swaps; the hook withdraws only the shortfall during each JIT cycle, deploys liquidity across owner-configured tick buckets, lets v4 execute against it, then re-deposits leftovers. LP shares are share-based via `PoolVault` (V2-style `sqrt(amount0 * amount1)` mint with locked `MINIMUM_SHARES`). Pricing is owner-controlled — the hook intentionally ignores `hookData` on swaps, so the signed-curve-update infrastructure inherited from `SpreadQuoterBase` is dormant.

`SmartPoolHook` is the strategy targeted for the upcoming external audit; the other reference quoters (open LP, Permit2 JIT, repositioning JIT) are tracked in follow-up work and will land as their own audit deliverables.

## **Layer 1b: Atomic Auction Hook**

The auction hook (`ALFMultiplexer`) provides atomic onchain competitive execution as an alternative to direct router routing. It is a **stateless** v4 hook deployed on a virtual (zero-liquidity) pool that exists solely as a dispatch mechanism. The router provides a targeted set of quoters to the auction hook via `hookData` — the auction hook does not discover quoters on its own.

The router decides per-swap whether to route directly or through the auction hook. This is a pure routing-level decision. Quoter hooks see the same `beforeSwap` invocation regardless of which path the router chose. The `sender` will differ (router vs. auction hook), but hooks should not gate on sender identity.

### Execution Model: Greedy Split Fill

Rather than picking a single winner, the auction fills targeted quoters sequentially from best to worst indicative. Each candidate receives the full remaining swap amount with a `sqrtPriceLimitX96` derived from the next candidate's current pool price. This causes the v4 swap loop to terminate when the current candidate's marginal price worsens to the next candidate's entry level, at which point remaining flow cascades to the next candidate. The result is an approximately optimal split that:

- Fills the best-priced quoter first until price impact equalizes with the next.
- Naturally handles quoters with different fee overrides and liquidity depths.
- Degenerates to single-quoter execution when only one target is provided.
- Works identically for exact-input and exact-output swaps.

### Execution Modes

`AuctionHookData` supports two modes, selected implicitly by the contents of the `targets[]` array:

- **Autonomous mode** (all targets carry `amountSpecified == 0`): the auction queries each target for an indicative quote, sorts by quote quality, and runs the greedy split fill described above. Fully self-contained — no offchain planning required.
- **Pre-planned mode** (any target carries `amountSpecified != 0`): the router has pre-computed the optimal split (e.g., using `swapToPrice` offchain). The auction executes targets in the supplied order with their specified amounts; a target with `amountSpecified == 0` mops up whatever remains. Skips indicative queries and sorting for lower gas at the cost of router-controlled execution.

Both modes support tolerance enforcement via `strictTolerancePips` and forward per-quoter `curveUpdateData` and shared `attestationData` to the nested swaps.

### Protocol Fee

The auction hook reads the v4 protocol fee from the virtual pool's slot0 and applies it to the unspecified delta after the split fill completes. Fees are taken directly to the protocol fee jar via `poolManager.take()`, mirroring the same mechanism used by aggregator hooks.

### Delta Forwarding

The auction hook's virtual pool has zero liquidity — all execution happens via nested `poolManager.swap()` calls on the candidates' real pools. The accumulated `BalanceDelta` from all fills is negated into a `BeforeSwapDelta` that offsets the virtual pool's swap, ensuring the auction hook's net position is zero. The outer caller receives the aggregate execution as their swap result.

### Notes

- Intuitively the auction hook is most valuable on mainnet and other slow or potentially adversarial builder environments, while direct routing is optimal for cheap gas and trusted sequencer setups like Base.
- Tolerance enforcement (`strictTolerancePips`) lets the router cap how far the executed price can drift from the baseline inside the auction transaction, providing an onchain backstop on top of the router's offchain reputation model. The baseline is the best pre-execution indicative, but each candidate's contribution is first bounded by its declared `getEffectiveLiquidity` (see `_baselineContribution`): a tier-1 indicative can be a constant-liquidity upper bound that overstates output for large swaps, and without the bound it would set an unreachable threshold and trip the check on a fair fill. The bound only reaches quoters that expose reserves (IALFHook); tier-2 simulator quotes are already exact and tier-3/4 opaque quoters cannot be bounded, which is why strict tolerance is a backstop over trusted targets and not a substitute for a router-side minimum-output / maximum-input check.
- Some metrics to weigh when deciding to use the auction hook vs direct routing:

    | **Property** | **Direct Routing** | **Auction Hook** |
    | --- | --- | --- |
    | Trust model | trusts the router to fairly route all trades | provides an on-chain fairness guarantee |
    | Gas cost | one pool query per quoter | multi-pool overhead + execution |
    | Flexibility | full flexibility, router controls flow entirely | constrained to auction rules, additional overhead |

## **Layer 2: Router (primary dispatch)**

The router is the primary dispatch layer and the core intelligence of the system. Its statistical model and historical data give it dispatch capabilities that cannot be replicated onchain.

### **Dispatch Flow**

1. Router receives swap request (pair, direction, amount, slippage, attestation)
2. Query known ALF hooks for the pair (discovered via router's own tracking, not an onchain registry)
3. Filter by liveness (`isLive()`), internal reputation scoring
4. For eligible quoters selected by the EV model (not exhaustively like the auction hook), `staticcall` to `getIndicativeQuote`, record indicated output and gas consumption.
5. (implicit router concern) Also query vanilla v4 pools, v2/v3 pools, external aggregators, etc.
6. Select best route (could be single pool or a split route)
7. Execute swap(s) on the selected pool(s)
8. Record actual execution output
9. Update reputation model (compare indicative vs actual output, etc.)

### **Quote Fidelity & Reputation Model**

The gap between indicative quotes and binding execution is the primary vulnerability of a router-dispatched architecture. The reputation model closes this gap through repeated-game incentives.

**Tracked metrics per quoter:**

| Metric | Definition | Impact |
| --- | --- | --- |
| Quote fidelity | Distribution of (actual − indicated) / indicated over a rolling window | Router discounts future indicatives by the observed fidelity gap |
| Win rate | How often the quoter's indicative is best, by pair/direction/size | Quoters that only win narrow contexts aren't called outside them |
| Fill rate | How often swaps routed to this quoter execute without reverting | Low fill rate → wasted gas → deprioritized |
| Revert tracking | Frequency and context of `beforeSwap` reverts after winning | Severe negative signal; persistent reverters are excluded |
| Gas accuracy | Observed gas vs. declared maxGas | Underdeclaring gas penalized in EV calculation |

**Fidelity-adjusted routing:**

For each quoter, the router computes:

```solidity
adjustedOutput = indicatedOutput × fidelityScore − gasCost
```

The router routes to the quoter with the highest adjusted output, subject to an explore/exploit strategy that allocates a budget for calling unproven quoters.

**Incentive alignment:** A quoter that over-indicates to win routing decisions but under-delivers at execution time sees its fidelity score drop, causing the router to stop routing to it. The equilibrium behavior is honest indication. The binding is not per-trade (a single trade can still have a gap) but per-quoter over time (consistent gaps lead to exclusion).

**Design Notes:**

- Discovery: The router maintains its own internal registry of known ALF hooks, populated through onchain event monitoring (pool creation events), manual registration endpoints, and partner integrations. For each known hook, the router queries `IALFHook` methods directly (`isLive()`, `maxGas()`, `getIndicativeQuote()`).
- Router maintains a model per quoter, keyed by `(quoterId, pair, direction, sizeRange)` which provides visibility on a per-quoter basis into things like
    1. EV vs vanilla routes
    2. Variance of observed vs expected improvement
    3. Variance of observed vs expected gas costs
    4. Historical fill rates (how often the quoter fades vs fills)
    5. Staleness of parameters (proxy for probability of successful execution)
    6. On Base gas is cheap enough that the additional overhead of many hops is less important and the router can chain more quoters together, whereas on mainnet the router would probably optimize more for shorter routes.
- Vanilla pools are the baseline against which the ALF route(s) are compared. Flow goes wherever the best EV exists, same as today.
- Off-chain routing gives lots of advantages over the pure on-chain auction hook for obvious reasons. We could have the router model over time how quoters perform and make more intelligent decisions based on observed outcomes. For example, quoters who consistently quote above baseline get queried less; quoters with high variance are queried more; size-dependent routing trends; volatility regimes; basically anything we find to be beneficial to routing outcomes.

## Liquidity Provisioning

With per-quoter pools, liquidity provisioning becomes a quoter-level concern rather than a hook-level concern. Each quoter manages their own liquidity model. Two patterns are exercised by the reference hooks shipped here:

### Native v4 LP with fee override

`SimpleSpreadQuoterHook` is the reference for this pattern. The maker holds standard v4 LP positions in the quoter's pool and the hook controls execution price by returning a per-direction fee override from `_beforeSwap`. The hook itself never touches tokens. LP additions are gated by an authorized-LP allowlist and constrained to a single tick-spacing range at the active tick.

### JIT LP with rehypothecation

`SmartPoolHook` is the reference for this pattern. Idle inventory is held in ERC4626 vaults (vault shares + ERC-6909 claims + per-pool ERC-20 sweep) between swaps. Each `_beforeSwap` redeems claims, withdraws only the shortfall from vaults, and deploys liquidity across multiple owner-configured tick buckets. `_afterSwap` removes the positions, settles the net deltas, and re-deposits leftovers. LP accounting is share-based via `PoolVault`, with V2-style `sqrt(amount0 * amount1)` mint and locked `MINIMUM_SHARES` to defuse share-price inflation attacks.

### Cross-pair inventory

A maker who wants isolation can deploy separate hooks, each with its own liquidity, curve, and pool. A maker who wants shared inventory can deploy a single hook that handles multiple pools, managing cross-pair risk controls internally. Neither pattern requires coordination with anyone else — pool registration is an entirely v4-native concern (`poolManager.initialize`).

## Security Considerations

### Quoter Isolation

Each quoter operates in its own pool with its own hook, which isolates code, state, and funds — but not in-transaction price. Quoters are deployed independently, each with its own hook instance and its own copy of any inherited base state, and the shared base contracts (`BaseALFHook`, `SpreadQuoterBase`, `PoolVault`, `SwapSimulator`, `ALFProtocolFees`) are abstract bases compiled into each quoter rather than shared mutable singletons, so a bug in one quoter's code cannot corrupt another's storage or the bases. And because v4 nets every currency delta to zero before an unlock finalizes, no quoter can extract another pool's funds through the multiplexer's nested swaps.

What that isolation does not cover is price and execution state. A quoter hook is an ordinary call frame with full v4 lifecycle access, not a constrained `staticcall`: when the multiplexer invokes a candidate's `beforeSwap` during a nested swap, that quoter can reenter the `PoolManager` and swap against another quoter's pool, moving its price or liquidity. The change persists once the outer unlock succeeds, and the multiplexer may trade against the manipulated state on a later fill in the same transaction. Integrators should treat the targeted quoters as mutually interactive and restrict the target set to hooks they trust.

A separate benefit of the per-quoter design is that it offers a similar guarantee to what the monolithic approach aimed for without relying on a strict `staticcall` paradigm. Quoters (particularly off-chain streaming quoters, but this applies to continuous quoters to an extent as well) are effectively able to avoid surfacing same-block pricing to competitors because there is no state update in the quoting process that competitors can leverage for insights.

### Off-chain Curve Manipulation

The one-curve-per-block enforcement prevents a maker from submitting different curve parameters to different swappers within the same block.

`BaseALFHook` implements this generically; signed curve updates are scoped by `(poolId, deadline)` and stale curves are rejected. The first curve seen in any given block is committed for all subsequent swaps in the same block. Makers can choose to override this base logic to support more sophisticated decisioning if desired.

### Router Trust

The router is the primary trust assumption in the direct routing path. A dishonest router could do things like:

- Exclude certain quoters to favor others
- Front-run by observing quote responses before committing
- Provide stale attestation data

Mitigations:

- The auction hook provides an atomic alternative for integrators who prefer strict on-chain fairness guarantees
- Multiple competing routers can exist; since hooks are self-describing, any router can query any hook directly.
- On-chain observability enables the post-hoc evaluation of router performance; a router that consistently fails to route to the best available price will be easily identified and the market will respond accordingly.

### Governance Fee Enforcement

For native quoters using v4's swap path (any hook that doesn't return a `BeforeSwapDelta`), v4's standard pool-level protocol fee applies and is collected by the PoolManager. The auction hook explicitly reads slot0's protocol fee via `ALFProtocolFees` and forwards it to the protocol fee jar after each split fill. Quoter hooks that intentionally bypass v4's swap math (e.g., a future delta-override quoter) would need to apply the protocol fee themselves; none of the hooks in this branch follow that pattern.

## Requirements

The list below tracks what is in scope for the upcoming external audit (P0), what is queued to follow (P1), and what remains aspirational (P2). Items marked with ✅ are landed on this branch.

### P0 (audit scope)

- ✅ **`IALFHook` interface.** `getIndicativeQuote`, `swapToPrice`, `isLive`, `maxGas`, `getReserves`, `getEffectiveLiquidity`. Standard `ALFHookData` envelope (`{attestationData, curveUpdateData}`).
- ✅ **`BaseALFHook` abstract base.** Standard hookData decoding, virtual `_resolveAttestation` extension point (default no-op), generic one-curve-per-block enforcement, default implementations of the read-only `IALFHook` methods, and `DeltaResolver` integration for settlement.
- ✅ **`SpreadQuoterBase` abstract base.** Bid/ask fee override scaffolding, EIP-712 signed curve updates against an owner-managed `priceSigner`, single-tick LP enforcement, `swapToPrice` powered by `SwapSimulator`.
- ✅ **`SwapSimulator` library.** Tick-walking swap simulation for indicative quotes and price-bounded planning. Quote-vs-execution fidelity is exercised by the test suite.
- ✅ **`PoolVault` abstract base.** Multi-asset share math (vault shares + ERC-6909 claims + per-pool ERC-20) with V2-style mint and locked `MINIMUM_SHARES`. Used by `SmartPoolHook`.
- ✅ **`SmartPoolHook` strategy hook.** Multi-range JIT spread quoter with ERC4626 vault rehypothecation. Audit deliverable for this branch.
- ✅ **`SimpleSpreadQuoterHook` baseline strategy.** Owner-restricted LP, single-tick concentration. Used as the auction hook's primary integration fixture.
- ✅ **`ALFMultiplexer`.** Stateless onchain auction with greedy split fill, autonomous + pre-planned execution modes, tolerance enforcement, and v4 protocol fee handling via `ALFProtocolFees`. Nested swap correctness exercised under v4's unlock model in the test suite.

### P1 (fast-follows, separate audit cycles)

- **Additional reference quoters.** Open LP, Permit2 JIT, and repositioning JIT variants are tracked in follow-up branches and will land as independent audit deliverables once `SmartPoolHook` is signed off.
- **Router integration: hook discovery.** The router discovers ALF hooks through onchain event monitoring and manual registration, then queries them directly via `IALFHook`.
- **Router integration: indicative quoting + reputation tracking.** The router calls `getIndicativeQuote` (and `swapToPrice` where helpful) on ALF hooks during routing and tracks indicative-vs-actual divergence and fill rate per quoter. Quoters with persistently poor fidelity are deprioritized.
- **Router: full EV-based dispatch model.** Marginal expected value calculation incorporating fidelity scores, win rates, gas costs, and historical dispersion. Explore/exploit strategy with configurable budget.
- **Attestation reference flow.** End-to-end demonstration from a Uniswap-frontend-issued attestation to a quoter's `_resolveAttestation` override consuming it for preferential pricing. The shared `BaseALFHook` envelope is in place; the producer side (signer infrastructure, distribution) is the open work.
- **Router: cross-pair state awareness.** Router tracks which quoters share state across pairs and factors large fills on one pair into EV estimates for related pairs.

### P2 (nice to haves, future)

1. **RFQ quoter type.** Dedicated hook implementation for request-for-quote flows.
2. **Router behavior auditing.** Onchain logging of routing decisions, transparent metrics, mechanisms for verifying router fairness.
3. **Multi-router competition.** Since hooks are self-describing via `IALFHook`, multiple independent routers can query any hook directly, creating competitive pressure on routing quality.

## Accompanying Infrastructure (async)

HookData-based updates require quotes to be available to the swapper (often via interface integration for retail users). JIT Storage-based updates require quotes to be available to sequencers.

We intend to define an accompanying reference implementation for MMs / integrators / builders that supports JIT price updates (both in the form of hookData-based updates, and JIT-sequenced storage-based updates). This will minimize integration friction for both MMs and integrators.
