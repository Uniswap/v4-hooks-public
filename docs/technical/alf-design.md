# ALF: Composable Quoter Design Doc

---

# Introduction

The Composable ALF concept described here is a layered hook architecture that enables proprietary market makers to operate custom AMMs within the Uniswap v4 ecosystem. Each quoter deploys its own v4 hook with full hook lifecycle access, shared infrastructure contracts handle cross-cutting concerns like attestation and discoverability, and the router drives intelligent dispatch through a statistical reputation model.

The proposal is largely motivated by the rapid growth of ALF volume on Base (from ~10% to ~40% of aggregator volume in ~2 months), coupled with our broader desire to enable more sophisticated proprietary trading strategies for LPs. On Base, ALF share of aggregator volume has grown from roughly 10-12% in late December/early January to approximately 40% and climbing. While aggregators are still a small percentage of total Base DEX volume (on the order of 5-6%), this trajectory represents a significant risk to Uniswap's market positioning on Base if we don't offer a competitive ALF product within the v4 ecosystem.

The core design is centered around router-driven discovery and dispatch with reputation-enforced quote fidelity. Competition between quoters is driven by the router's EV model, which tracks historical quote accuracy, fill rates, and win rates per quoter. The atomic auction hook is available for environments (e.g., mainnet) where on-chain fairness guarantees are required. The decision of whether to route directly or through the auction hook is a pure routing-level concern; quoters do not opt in or out. Hooks expose their own metadata via the `IALFHook` interface — no shared registry is required.

# Design Philosophy

The original ALF proposal concentrates registry management, competitive dispatch, fallback comparison, flow attestation, and liquidity provisioning into a single monolithic hook. This revised design decomposes those concerns into independent, composable layers that align more closely with v4's native primitives. 

Rather than re-implementing core AMM logic modified for competitive quoting inside a hook, we push competition to the router layer and give each quoter the full hook lifecycle to work with. Shared concerns (attestation, flow-quality signals) live in thin infrastructure contracts that any hook can read from, while hook metadata (indicative quotes, liveness, gas budgets, reserves) is exposed directly by each hook via the `IALFHook` interface. This model scales to an arbitrary number of quoters, imposes minimal constraints on quoter architecture and complexity, and requires no coordination for introducing new quoter types.

The architecture is shaped by several key assumptions:

- **Quoter flexibility is the whole point.** The complexity of proprietary market making is such that no single interface or curve model could cover the range of optimizations makers need to compete effectively. Quoters need access to the full v4 hook lifecycle (e.g., `afterSwap` for post-trade analytics, dynamic fees, custom curve logic, arbitrary state management), not a tightly constrained quoting API.
- **Dispatch intelligence belongs in the router.** The router has access to historical data, statistical models, and per-quoter reputation tracking that cannot be efficiently replicated onchain. Putting dispatch logic inside a hook means calling every quoter exhaustively and picking the best, which is the least efficient selection strategy and doesn't scale as the quoter set grows.
- **Each component should have a small, independent audit surface.** Shared infrastructure (index, attestation) is thin and static. Quoter hooks are independently deployed and independently auditable. A bug in one quoter's pricing logic cannot affect other quoters.
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
| 0 | Shared Infrastructure | Attestation (AttestationRegistry), standard interfaces (IALFHook), base implementation (BaseALFHook) |
| 1a | Quoter Hooks | Individual v4 hooks per market maker. Full hook lifecycle, custom pricing, independent deployment. Each hook exposes its own metadata via `IALFHook`. |
| 1b | Auction Hook | Stateless atomic competitive round. Receives targeted quoter set via `hookData`, queries indicative quotes, routes to best quoter. |
| 2 | Router | Primary dispatch. EV-based quoter selection, reputation model, quote fidelity tracking, fallback management. |

Information flows downward: the router queries quoter hooks directly (via `IALFHook`) and routes to the best pool. Quoter hooks read shared infrastructure (attestation registry) but are otherwise independent. The auction hook is a transparent intermediary; quoters see the same `beforeSwap` invocation regardless of whether the swap was initiated by the router directly or through the auction hook.

## **Layer 0: Shared Infrastructure**

These are supporting contracts that any hook or router can query. No execution logic.

### Self-Describing Hooks (IALFHook)

Each ALF hook exposes its own metadata directly via the `IALFHook` interface. There is no shared onchain registry — hooks are self-describing. The router discovers hooks through its own tracking and queries them directly.

**Design Notes**

- **No coordination required:** Deploying a new hook doesn’t require registering with any shared contract. The router discovers hooks and builds its candidate set independently.
- **Liveness:** Self-reported by the hook via `isLive()`. Routers treat this as a hint and validate against observed behavior.
- **Metadata:** `maxGas()` declares the gas budget for indicative quoting. `getReserves()` and `getEffectiveLiquidity()` report TVL and immediately available liquidity.
- **Simplicity:** Removing the registry eliminates a coordination point and a potential governance surface. Spam resistance is handled entirely at the router layer via the reputation model.

### **AttestationRegistry**

A shared registry of attestation keys. Any ALF hook can verify flow attestation against this registry, which decouples attestations from individual hooks.

**Design Notes**

- **Scope:** Attestations are scoped per-swap via `swapHash` and time-bounded via `deadline`. This prevents replay.
- **Read-only from hooks:** The registry only verifies. Each quoter independently decides how to use attestation data (e.g., preferential pricing for attested flow).
    - Hooks can call `verifyAttestation` in their `beforeSwap` if attestation is present in `hookData` which will verify it against the registry. This can be used for delivering preferential/predefined pricing which can take precedent over whatever the ALF would have otherwise returned at the time of execution. If no attestation is present, the quoter should fall back to its default behavior.
- **Reference model:** Jupiter's attestation model was reviewed in the process of designing the signature scheme and payload format.
- **Governance-controlled attester list:** Keys can be registered for e.g. trading-api or other systems that receive and process quotes from makers which are attested and delivered with swap payloads.

See the [relevant formal spec section](https://www.notion.so/ALF-Formal-Spec-311c52b2548b80589834cd397c8f6ab7?pvs=21) for interface and implementation details.

## **Layer 1a: Quoter Hooks**

Each market maker deploys its own v4 hook controlling a pool for the pair it quotes on. The hook has full authority over pricing logic, state management, the complete hook lifecycle (`beforeSwap`, `afterSwap`, `beforeAddLiquidity`, etc.), liquidity model, and liveness reporting.

**Update Modes**

| Mode | Pricing Inputs | State Updates | Best For |
| --- | --- | --- | --- |
| Storage-based | Hook reads coefficients from its own storage | Maker writes via standalone transactions (keeper, oracle, manual, block builder) | Major pairs on cheap-gas chains where per-block updates are affordable, or curves robust to staleness |
| hookData-based | Caller submits signed parameters via `hookData` at swap time | Written to storage on first swap per block; subsequent swaps reuse cached params | Mainnet (expensive updates), lower-volume pairs, long-tail tokens, makers needing sub-block pricing freshness |
| External (wrapped) | Thin v4 hook wrapping an external ALF contract | Implementation-specific | Existing ALFs (Tessera, ElFomoFi) |

A single hook can support both modes: read from `hookData` when fresh signed parameters are provided, fall back to stored coefficients when they aren't. The router tracks quoter behavior patterns (update frequency, parameter staleness) as part of its reputation model, not via a registry metadata field.

Hooks using hookData-based updates enforce the one-curve-update-per-block invariant via a per-block hash mapping. Storage-based and hookData-based modes are best kept as separate hook deployments when the maker wants clean separation, but this is a maker operational decision, not an architectural requirement.

Extending the base hook gives quoters a few things for free: attestation verification (attestation is validated and passed to the internal quoting function, quoters decide what to do with it… discount, no-op, etc.), one-curve-per-block enforcement (off-chain quoters can submit updated signed curves and ensure consistency within a block), clean separation of pricing and state mutation (e.g. a `_price` function returns the delta, `_postSwap` handles any state changes). They still control their curve and all parameters, how they respond to attested/unattested flow, inventory/risk management, whether to support off-chain curve updates at all, and any other hook lifecycle stuff they want. It benefits hook developers to extend the base, however this is not a hard requirement.

- Examples (rough sketches, WIP):
    - **Storage-based Quoter**
        
        ```solidity
        contract WintermuteALF is BaseALFHook {
            mapping(PoolId => PricingState) internal state;
        
            function _price(
                PoolKey calldata key,
                bool zeroForOne,
                int256 amountSpecified,
                bool isAttested,
                address attester
            ) internal view override returns (uint256 outputAmount) {
                PricingState memory s = state[key.toId()];
                uint256 baseOutput = _computeCurve(s, zeroForOne, amountSpecified);
        
                // Offer better pricing for attested (non-toxic) flow
                if (isAttested) {
                    baseOutput = baseOutput * 10005 / 10000; // 1/2 bps discount
                }
        
                return baseOutput;
            }
        
            function beforeSwap(
                address sender,
                PoolKey calldata key,
                IPoolManager.SwapParams calldata params,
                bytes calldata hookData
            ) external override returns (bytes4, BeforeSwapDelta, uint24) {
                (IAttestationRegistry.Attestation memory att, bool valid) =
                    _parseAttestation(hookData);
        
                uint256 output = _price(
                    key, params.zeroForOne, params.amountSpecified, valid, att.attester
                );
        
                _updateState(key, params, output);
        
                return (this.beforeSwap.selector, _toDelta(params, output), 0);
            }
        }
        ```
        
    - **`hookData` Based Quoter**
        
        ```solidity
        contract OffchainALF is BaseALFHook {
            mapping(PoolId => mapping(uint256 => bytes32)) internal blockCurveHash;
            mapping(PoolId => CurveParams) internal currentCurve;
        
            function beforeSwap(
                address sender,
                PoolKey calldata key,
                IPoolManager.SwapParams calldata params,
                bytes calldata hookData
            ) external override returns (bytes4, BeforeSwapDelta, uint24) {
                (CurveParams memory curve, bytes memory sig) =
                    abi.decode(hookData, (CurveParams, bytes));
        
                PoolId pid = key.toId();
                bytes32 curveHash = keccak256(abi.encode(curve));
        
                if (blockCurveHash[pid][block.number] == bytes32(0)) {
                    _verifyCurveSignature(curve, sig);
                    blockCurveHash[pid][block.number] = curveHash;
                    currentCurve[pid] = curve;
                } else {
                    require(
                        blockCurveHash[pid][block.number] == curveHash,
                        "conflicting curve update"
                    );
                }
        
                uint256 output = _priceFromCurve(currentCurve[pid], params);
                return (this.beforeSwap.selector, _toDelta(params, output), 0);
            }
        
            function quoteEndpoint() external view returns (string memory) {
                return "wss://quotes.maker.com/v1/stream";
            }
        }
        
        ```
        

### External ALF Integration

External ALFs (Tessera, ElFomoFi, etc.) are handled via two non-exclusive paths:

- **Wrapper hook:** Brings them into the v4 ecosystem, implementing `IALFHook` to enable router discoverability and (optionally) attestation system integration.
- **Router-level integration:** The router handles them as external liquidity venues alongside Uniswap v2/v3 pools, requiring no onchain wrapping.

A governance-configurable fee on external ALFs can be implemented in wrapper hooks (simple but easily forked without the fee) or as a router-level surcharge (more flexible). Needs legal opinion.

## **Layer 1b: Atomic Auction Hook**

The auction hook provides atomic onchain competitive quoting as an alternative execution strategy. It is a **stateless** v4 hook deployed on a virtual pool that exists solely as a dispatch mechanism. The router provides a targeted set of quoters to the auction hook via `hookData` — the auction hook does not discover quoters on its own.

The router decides per-swap whether to route directly or through the auction hook. This is a pure routing-level decision. Quoter hooks see the same `beforeSwap` invocation regardless of which path the router chose. The `sender` will differ (router vs. auction hook), but hooks should not gate on sender identity.

The auction hook calls `getIndicativeQuote` on the targeted quoters via `staticcall` within its `beforeSwap`, selects the best quote, and executes the swap on the winning quoter's pool via a nested `poolManager.swap` call.

**Scalability constraint:** Gas cost scales with the number of targeted quoters. The router controls this by selecting a reasonable candidate set. The hook has no statistical model and cannot perform intelligent dispatch — it evaluates all provided quoters exhaustively.

**Delta forwarding:** The auction hook’s `BeforeSwapDelta` must correctly reflect the `BalanceDelta` from the nested swap on the winning quoter’s pool.

**Notes:**

- Intuitively I think this would be optimal for mainnet and other slow or potentially adversarial builder environments, while direct routing is optimal for cheap gas and trusted sequencer setups like Base.
- It might be prudent to only allow quoters that extend the `BaseALFHook` to considered for routing. This allows us to enforce on-chain compliance with their indicatives; if the execution output is different from the indicative quote by more than a bp or two, revert and mark up that quoter’s indicatives for future rounds by a decaying amount based on the delta.
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

With per-quoter pools, liquidity provisioning becomes a quoter-level concern rather than a hook-level concern. Each quoter manages their own liquidity, whether native to V4 (i.e. existing LP positions) or external.

### For “native” ALFs (liquidity flows via V4 core)

The quoter’s hook controls how liquidity is deposited, withdrawn and accounted for in their pool. This could include depositing on-demand into the pool via `modifyLiquidity` just-in-time for swaps and/or maintaining some stable base of liquidity in the pool generally.

### For external ALFs (ex-V4 liquidity sources)

External ALFs like Tessera or ElFomoFi can be wrapped with an adapter that doesn’t technically need a pool of its own (but could have one with “virtual liquidity” like @Eric Sanchirico’s aggregator hook model). This would basically be the minimum viable integration, and it carries the same tradeoffs noted in the original proposal (double execution, invariant checks, higher gas), but it’s cleanly isolated in its own adapter rather than adding complexity to a shared hook. From the router’s perspective, there’s no real difference.

### Cross-pair inventory

The original proposal raised the question of dedicated allocation per-pair vs shared pools. With per-quoter hooks, this is a quoter implementation decision. A maker who wants isolation might deploy separate hooks, each with its own liquidity, curve, etc., while a maker who wants shared inventory can deploy a single hook that can handle multiple pairs and attach that one hook to multiple pools, managing cross-pair risk controls internally. The registry supports both because it’s indexed by pair, and a single hook address can support multiple pairs. This is strictly more flexible than either Option 1 or Option 2 from the original proposal, because it doesn't force a single model on all quoters.

## Security Considerations

### Quoter Isolation

Each quoter operates in its own pool with its own hook. A bug or exploit in one quoter cannot affect other quoters, the PoolManager, or the shared infrastructure contracts. Another benefit of the per-quoter design is that it offers a similar guarantee to what the monolithic approach aimed for without relying on a strict `staticcall` paradigm. Quoters (particularly off-chain streaming quoters, but this applies to continuous quoters to an extent as well) are effectively able to avoid surfacing same-block pricing to competitors because there is no state update in the quoting process that competitors can leverage for insights.

### Off-chain Curve Manipulation

The one-curve-per-block enforcement prevents a maker from submitting different curve parameters to different swappers within the same block (optional, maker chooses). 

The `BaseALFHook` implements this generically; signed curve params include a timestamp, and stale curves are rejected. The first curve seen in any given block would be essentially committed for all future swaps in the same block. Makers can choose to override this base logic to support more sophisticated decisioning if desired.

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

If governance wants to charge a fee on ALF swaps:

- For native quoters, the fee can be enforced directly via the standard V4 swap flow. Typical pool-level protocol fees can be applied here by taking a cut of the delta the way it normally would.
- For external quoters routed through adapters (not via v4 pools), the adapter can impose the fee and the router can enforce it by excluding unaligned adapters.

## Requirements

### P0 (must have for v1):

- **AttestationRegistry contract.** Governance-managed attester whitelist. Per-swap scoped attestation verification. Read-only from hooks.
- **IALFHook interface specification.** Published as an EIP-style interface with `getIndicativeQuote`, `isLive`, `maxGas`, `getReserves`, and `getEffectiveLiquidity`.
- **BaseALFHook reference implementation.** Attestation parsing, `IALFHook` defaults, standard hook lifecycle. Audited.
- **At least one reference quoter hook.** A storage-based onchain quoter extending `BaseALFHook`, demonstrating the full integration path. Used for internal testing and as onboarding documentation for makers.
- **Router integration: hook discovery.** The router discovers ALF hooks through onchain event monitoring and manual registration, then queries them directly via `IALFHook`.
- **Router integration: indicative quoting.** The router calls `getIndicativeQuote` on ALF hooks during routing and uses the results in its route selection.
- **Router integration: basic reputation tracking.** The router tracks indicative-vs-actual divergence and fill rate per quoter. Quoters with persistently poor fidelity are deprioritized. The model can be simple (rolling averages) for v1; sophistication comes later.
- **External ALF wrapper hook for Tessera and ElFomoFi.** Thin wrappers that bring existing external ALFs into the v4 ecosystem via `IALFHook`. Validates that the architecture works with real production quoters.
- **Auction hook.** Stateless atomic onchain competitive quoting for mainnet deployment. Receives targeted quoter set from router via `hookData`. Nested swap confirmed safe under v4 unlock model; delta forwarding correctness requires audit.

### P1 (should haves, fast-follows)

- **hookData-based quoter hook reference implementation.** Demonstrates signed curve updates, one-update-per-block enforcement, and `quoteEndpoint` exposure.
- **Router: full EV-based dispatch model.** Marginal expected value calculation incorporating fidelity scores, win rates, gas costs, and historical dispersion. Explore/exploit strategy with configurable budget.
- **Governance fee on external ALFs.** Implemented in wrapper hooks. Fee level configurable by governance.
- **Attestation system finalization.** Signature scheme, payload format, and integration with Jupiter's model. End-to-end flow from Uniswap frontend attestation to quoter preferential pricing.
- **Router: cross-pair state awareness.** Router tracks which quoters share state across pairs and factors large fills on one pair into EV estimates for related pairs.

### P2 (nice to haves, future)

1. **RFQ quoter type.** Dedicated hook implementation for request-for-quote flows.
2. **Router behavior auditing.** Onchain logging of routing decisions, transparent metrics, mechanisms for verifying router fairness.
3. **Multi-router competition.** Since hooks are self-describing via `IALFHook`, multiple independent routers can query any hook directly, creating competitive pressure on routing quality.

## Accompanying Infrastructure (async)

HookData-based updates require quotes to be available to the swapper (often via interface integration for retail users). JIT Storage-based updates require quotes to be available to sequencers.

We intend to define an accompanying reference implementation for MMs / integrators / builders that supports JIT price updates (both in the form of hookData-based updates, and JIT-sequenced storage-based updates). This will minimize integration friction for both MMs and integrators.