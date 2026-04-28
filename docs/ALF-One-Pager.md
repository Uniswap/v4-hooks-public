# ALF: Proprietary Market Making on Uniswap v4

## The Opportunity

Proprietary AMM volume on Base has grown from ~10% to ~40% of aggregator volume in under two months. Uniswap's ALF framework brings this activity natively into the Uniswap v4 ecosystem, giving market makers access to the full hook lifecycle to run custom pricing strategies that work with Uniswap's router, liquidity infrastructure, and user base. Makers can leverage our just-in-time configuration update mechanism to keep their pricing fresh without manually pushing price updates to the blockchain, and attestations help makers understand and make informed decisions about the nature of the flow seen by ALFs.

## What It Is

Our ALF framework is a flexible, composable hook architecture built on top of Uniswap v4 that lets professional market makers deploy their own pools with proprietary pricing strategies on top of v4's concentrated liquidity curve. Each maker gets an independent pool with full control over spread management, liquidity positioning, and execution strategy — no shared-state risks, no constrained quoting APIs.

The system has four layers:

- **Shared Infrastructure** — An `AttestationRegistry` for flow-quality signals and the `IALFHook` standard interface that all hooks implement. These components act as supportive tooling for ALFs; they contain no execution logic.
- **Quoter Hooks** — Each maker deploys a v4 hook implementing `IALFHook` with full access to all hook lifecycle methods (e.g., `beforeSwap`, `afterSwap`), which can support things like dynamic fee overrides, strategic liquidity positioning immediately before or after a swap, and arbitrary state for tracking market conditions. Hooks expose their own metadata directly — indicative quotes, liveness, gas budgets, and reserve reporting — with no shared registry dependency.
- **Auction Hook** — A stateless onchain auction for environments requiring atomic fairness guarantees. Receives a targeted set of quoters in `hookData`, queries indicative quotes, and executes on the best pool with configurable quote fidelity enforcement. The auction hook acts as a single pool which allows routers to support a wide range of ALF strategy hooks without integrating each independently.
- **Router** — Primary dispatch layer. Uses a statistical reputation model (quote fidelity, fill rates, win rates, gas accuracy) to intelligently select among quoters without exhaustive onchain enumeration. Our router also provides just-in-time context injection and granular flow attestation which allows makers to delegate pricing configuration changes to the swapper and make informed decisions about the swap requests their strategy serves.

## Key Design Decisions

### Building on v4's concentrated liquidity curve

ALF strategies express proprietary pricing through v4's hook lifecycle — dynamic fee overrides, strategic liquidity positioning, and signed parameter updates — rather than replacing v4's curve math with fully custom pricing functions. This is a deliberate constraint with several implications:

- **Protocol fee enforceability.** v4 protocol fees are applied by the PoolManager during swap execution on the CLAMM curve. Hooks that override the curve with return-delta pricing bypass this mechanism entirely. Requiring the v4 curve ensures protocol fees work without additional enforcement.
- **Composability.** Hooks that use the native curve are composable with existing v4 infrastructure — routers, position managers, analytics tooling. Custom curve hooks break these assumptions.
- **Audit surface.** The v4 curve has been extensively audited. Quoter hooks only need to be audited for their strategy logic (fee selection, positioning, attestation handling), not core swap math.

We believe dynamic fees and positioning control are expressive enough for the strategies that matter most. **We'd like your feedback on whether this is true for your use cases** — what strategies, if any, require full curve replacement rather than parameterization of the existing curve?

### Per-quoter pool isolation

Each maker gets their own v4 pool. This means:

- **No information leakage.** Our quote-then-execute flow and per-quoter pools mean competitors cannot observe your state updates during the quoting process.
- **Fault isolation.** A bug in one maker's strategy cannot affect other quoters, the PoolManager, or shared contracts.
- **Independent auditability.** Each hook is a self-contained contract that can be reviewed in isolation.

The tradeoff is liquidity fragmentation — each pool has its own liquidity rather than sharing a single deep pool. In practice, this is acceptable because ALF makers manage their own inventory (they aren't relying on passive LPs for depth), and the router aggregates across pools to find the best price for swappers.

### Router-driven dispatch as the primary path

The router, not the onchain auction hook, is the primary dispatch mechanism. The router has access to historical data, statistical models, and per-quoter reputation tracking that cannot be efficiently replicated onchain. This means:

- **Intelligent selection.** The router doesn't query every quoter exhaustively — it uses an EV model to include the most likely winners based on pair, direction, size, and historical performance. The router then uses the onchain auction hook to enforce quote fidelity and ensure swap outcomes match user expectations.
- **Reputation enforcement.** Quote fidelity, fill rates, win rates, and gas accuracy are tracked per quoter. Makers that over-indicate to win flow but under-deliver at execution see fidelity scores drop and get deprioritized. The auction hook reinforces the router's reputation model by preventing quoters from meaningfully deviating at execution time.
- **Trust model.** Direct routing trusts the router to fairly select quoters. For environments where this trust assumption is unacceptable (e.g., mainnet), the atomic auction hook provides onchain fairness guarantees at the cost of higher gas (exhaustive quoter enumeration).

## How Pricing Works

ALF strategies build on v4's native concentrated liquidity curve rather than replacing it. This gives makers the battle-tested pricing mechanics of the CLAMM while adding proprietary control over the parameters that matter most:

- **Dynamic bid/ask spreads** — Fee overrides let makers set independent fees for each swap direction, updated per-block via signed `hookData`. The underlying swap still executes against v4's concentrated liquidity math.
- **Liquidity positioning** — Makers control where their LP is concentrated (single-tick or custom ranges) and can auto-reposition before or after swaps based on market conditions, all through the hook lifecycle.
- **Signed JIT curve updates** (EIP-712) — Signed pricing parameter updates are delivered by swappers via `hookData` just-in-time at swap time with optional one-update-per-block enforcement to prevent intra-block manipulation. Makers can rely on swapper activity to update spreads frequently without needing to run a cost-intensive keeper service to dispatch onchain transactions for this purpose.
- **Direct maker curve updates** — Makers can also run their own curve updating keeper service to ensure onchain pricing stays fresh and competitive without relying on swaps against their pools delivering parameter changes. These direct configuration updates can either work exclusively or alongside the signed JIT curve update mechanism, including reserving certain parameters exclusively for the direct update path.

### Indicative quotes and execution fidelity

Every quoter hook exposes `getIndicativeQuote` — a `view` function that the router and auction hook call via `staticcall` to preview pricing before committing to a swap. In the reference implementations, the indicative quote is computed using a `SwapSimulator` that replicates v4's tick-walking loop against the pool's current state, including the maker's fee override and any JIT context carried by the swap's `hookData`. This ensures indicatives closely track actual execution.

Indicatives are explicitly **non-binding** — a single trade can diverge from its indicative insofar as the deviation doesn't exceed the user's configured slippage and/or quote fidelity bounds. But the router's reputation scoring model tracks this and other metrics, and the reputation score is directly correlated to the amount of routing flow quoters will see. The equilibrium behavior is honest indication, which is to say that quotes should generally be treated as binding to the extent the maker wants to remain competitive with other ALF quoters and classic AMM pools.

## Flow Attestation

The `AttestationRegistry` enables makers to distinguish order flow quality. Swaps arriving through trusted frontends (e.g., the Uniswap interface, MetaMask) carry attestations that hooks can consider in their pricing logic. For example, makers can effectively reduce adverse selection and improve LP economics by establishing wider default spreads that price in toxicity risk and leveraging attestation proofs to offer tighter quotes for non-toxic flow.

An example of attestation-aware pricing is built into the spread quoter model. A spread quoter's pricing state includes an `attestedDiscountBps` parameter that reduces the effective fee override for attested swaps. When a swap carries a valid attestation, the hook verifies it against the `AttestationRegistry` in `beforeSwap` and applies the discount as a direct reduction to the bid or ask fee (1 bps = 100 pips fee reduction). The same fee reduction is applied in indicative quotes, ensuring quote fidelity between indication and execution. Makers configure the discount alongside their bid/ask spreads and can update it per-block via the same signed curve update mechanism.

## Integration Path for Market Makers

1. **Extend `SpreadQuoterBase`** (or `BaseALFHook` directly) and implement your pricing strategy — spread parameters, positioning logic, and attestation handling.
2. **Deploy your hook** on a v4 pool for each pair you want to quote. The hook implements `IALFHook` directly, exposing indicative quotes, liveness, gas budgets, and reserve reporting.
3. **Set up a price signer** for streaming offchain strategy configurations if you intend to use our just-in-time `hookData`-based configuration updates. We'll provide a reference implementation that demonstrates this functionality.
4. **Start quoting** — the router discovers your hook and includes it in its candidate set based on pair and reputation.

No special permissions or coordination with other quoters is required. Your hook is independently deployed and independently auditable.

## What We Need From Partners

### Strategy expressiveness
Are dynamic fee overrides and liquidity positioning sufficient to express your strategies on top of v4's concentrated liquidity curve? What specific strategies, if any, require full curve replacement? Understanding the boundary of what's expressible helps us decide whether to keep the v4 curve requirement strict or introduce a controlled path for custom curves.

### Attestation design
- How do you classify flow quality today, and how does classification affect your quoting?
- What signals beyond frontend origin matter for your pricing decisions (e.g., sender history, trade size, time-of-day)?
- What spread differential do you typically apply between retail/non-toxic flow and informed/toxic flow? The current model expresses this as a fee reduction in bps — is a single discount parameter sufficient, or do you need more granular control (e.g., per-pair, per-size-bucket, or tiered discounts)?

### Operational requirements
- What `maxGas` budget does your quoting logic require? Declared gas limits affect how the router and auction hook call your hook.
- How frequently do you expect to update pricing parameters? Per-block? Sub-block via multiple `hookData` submissions?
- Do you have existing infrastructure (keepers, off-chain signers) that would integrate with EIP-712 signed curve updates, or would you rely on our reference tooling?

### Execution path preferences
- Do you have a preference between direct routing (router-selected, lower gas, trust-the-router model) and atomic auction (onchain fairness, higher gas, exhaustive comparison)?
- Are there environments or pairs where one path clearly dominates for your strategy?

## Contracts (Draft)

| Contract | Description |
|---|---|
| `AttestationRegistry` | Attestation verification, governance-managed attester list |
| `IALFHook` | Standard interface: indicative quotes, liveness, gas budgets, reserve reporting |
| `BaseALFHook` | Abstract base; implements `IALFHook`, attestation resolution, standard hook lifecycle |
| `SpreadQuoterBase` | Bid/ask spread pricing via fee overrides and concentrated LP; SwapSimulator for precise quoting |
| `ALFMultiplexer` | Stateless onchain competitive auction, one per chain |
| `SimpleSpreadQuoterHook` | Reference: spread quoter with maker-only LP |
| `AaveRehypothecatingSpreadQuoterHook` | Reference: spread quoter with auto-repositioning LP and Aave-sourced yield on idle capital |

---

*Uniswap Labs — Draft, March 2026*
