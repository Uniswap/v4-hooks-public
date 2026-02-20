## Overview

The Tempo Aggregator Hook is a Uniswap V4 hook that routes swaps through Tempo's enshrined stablecoin DEX. Rather than holding its own liquidity, the hook acts as a bridge: when a user swaps through a Uniswap V4 pool backed by this hook, the hook intercepts the swap in `beforeSwap`, executes it against the Tempo exchange precompile, and returns the result to the PoolManager. From the user's perspective, they are swapping through Uniswap. Under the hood, the trade settles on Tempo's native DEX.

This design brings Tempo's stablecoin liquidity into the Uniswap routing graph, allowing routers to discover, quote, and compose these pools alongside native Uniswap V4 pools.

## Hook vs Pool: Singleton Architecture

### One Hook, Many Pools

The `TempoExchangeAggregator` is deployed as a **singleton**, a single hook instance that serves every Tempo-backed pool. Each supported token pair gets its own Uniswap V4 pool (identified by a unique `PoolId`), but all of these pools share the same hook contract address.

```
┌──────────────────────────────────────────────────┐
│              TempoExchangeAggregator             │
│                  (singleton hook)                │
│                                                  │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│   │  Pool A  │  │  Pool B  │  │  Pool C  │       │
│   │ USDC/USDT│  │ USDC/DAI │  │ USDT/DAI │       │
│   └──────────┘  └──────────┘  └──────────┘       │
│                                                  │
│         poolIdToTokens mapping resolves          │
│         each PoolId → (token0, token1)           │
└──────────────────────────────────────────────────┘
                       │
                       ▼
        ┌──────────────────────────┐
        │    Tempo Exchange        │
        │  (precompile 0xDEc0...)  │
        └──────────────────────────┘
```

### Why One Pool Per Pair?

Uniswap V4's `PoolKey` is defined by `(currency0, currency1, fee, tickSpacing, hooks)`. The PoolManager requires each tradable pair to have its own pool. There is no concept of a multi-asset pool at the V4 level. To expose Tempo's N-token exchange to Uniswap's routing layer, we create one V4 pool for each pair.

This is also important for composability. A Uniswap V4 router builds multi-hop routes by chaining individual pools. If a user wants to go from Token A → Token B → Token C, the router needs discrete Pool(A,B) and Pool(B,C) entries to construct the path. Without per-pair pools, the router cannot discover or quote these individual legs.

### Why Singleton?

A singleton design (one hook, many pools) is chosen over per-pair deployment for several reasons:

1. **Gas efficiency**. Deploying one contract instead of N is cheaper. Pool registration happens through `initialize()`, not a new deployment.
2. **Simpler upgrades**. A single hook address to manage across all pairs.
3. **Router signal**. When the router sees the same hook address across multiple pools, it knows they share the same underlying liquidity source (the Tempo exchange). This is critical for avoiding interference between hops (see Multi-Hop Safety below).

## Pair Selection: The Tempo DEX Tree

### How Pairs Are Determined

Not every possible combination of Tempo-listed tokens should get a Uniswap V4 pool. Pair selection follows Tempo's DEX tree structure, which defines the canonical trading pairs on the exchange. The tree ensures we only create pools for directly supported pairs and not rely upon Tempo's routing.

During pool initialization, the hook validates that Tempo actually supports the pair:

```solidity
// _beforeInitialize validates by attempting a quote
try tempoExchange.quoteSwapExactAmountIn(token0, token1, 1) {}
catch {
    revert TokensNotSupported(token0, token1);
}
```

If Tempo's exchange does not recognize the pair, initialization reverts with `TokensNotSupported`.

### Multi-Hop Safety and the DEX Tree

A key design constraint: **we do not create pools for pairs that would only be serviceable via multi-hop on Tempo** (credit @Eric Sanchirico). This guarantees that every Uniswap V4 pool backed by this hook represents a direct, atomic swap on the Tempo exchange.

Why this matters for routing:

Consider tokens A, B, and C where Tempo supports A↔B and B↔C directly, but A↔C only via A→B→C. If we created a Uniswap V4 pool for A↔C that internally multi-hopped through B on Tempo, and the router also built a path A→B→C using the individual V4 pools, the two paths would interfere. The A↔C pool's internal B leg would compete with the explicit B↔C pool for the same underlying liquidity.

By restricting to direct pairs from the DEX tree, we guarantee:

- **No hidden liquidity interference**. Each V4 pool maps to an independent leg on Tempo.
- **Safe hop composition**. The router can freely chain Pool(A,B) → Pool(B,C) without risk of two pools contending for the same liquidity within a single transaction.
- **Accurate quoting**. A quote for Pool(A,B) will not be invalidated by a simultaneous swap through Pool(A,C) that internally touches the A↔B market.

## TVL (For the Routing Team)

### What TVL Represents

The `pseudoTotalValueLocked` function reports the token balances held by the Tempo exchange for each pool's pair:

```solidity
function pseudoTotalValueLocked(PoolId poolId)
    external view override
    returns (uint256 amount0, uint256 amount1)
{
    PoolTokens storage tokens = poolIdToTokens[poolId];
    amount0 = IERC20(tokens.token0).balanceOf(address(tempoExchange));
    amount1 = IERC20(tokens.token1).balanceOf(address(tempoExchange));
}
```

### How to Retrieve TVL

Call `pseudoTotalValueLocked(poolId)` on the hook contract. It returns the `(amount0, amount1)` balances of the pool's tokens held by the Tempo exchange precompile. This is a `view` function and can be called off-chain at no gas cost.

Note the values are `uint256` even though Tempo uses `uint128` internally. The ERC-20 `balanceOf` returns `uint256`.

### Why We Cannot Use On-Chain Events

Liquidity in Tempo's exchange is **managed externally** to the Uniswap V4 pool. The hook itself holds no liquidity; it is a pass-through. This means:

1. **No Uniswap V4 liquidity events**. Standard `Mint`/`Burn` events from Uniswap V4 pools will never fire for these pools because no one is providing liquidity through the V4 interface. The V4 pool has no ticks, no positions, no LPs.
2. **No hook-emitted liquidity events**. The hook does not manage, add, or remove liquidity. It only routes swaps. There is nothing for it to emit.

**Recommendation for the routing team**: Poll `pseudoTotalValueLocked` periodically to get current liquidity levels. Do not rely on event-driven indexing for these pools. The returned balances represent the total liquidity available on the Tempo exchange for those tokens, not liquidity dedicated to any single pair, since the Tempo exchange is a shared pool.

### TVL Caveat: Shared Liquidity

Because the Tempo exchange is a single shared entity, `pseudoTotalValueLocked` for Pool(A,B) and Pool(A,C) will return the **same `amount0` for token A**. The reported TVL per pool is not exclusive. It represents the full exchange balance, which is shared across all pairs involving that token. The routing team should account for this when estimating available depth.

## Gas Considerations

### Tempo Aggregator Hook, Gas Analysis

Gas comparison between direct Tempo DEX swaps and swaps routed through the Uniswap V4 aggregator hook. All measurements taken on Tempo Moderato testnet (chain 42431) with 100-token exact-input swaps using precompile stablecoins (6 decimals).

### TIP-20 DEX Tree

Each TIP-20 token specifies a `quoteToken()` that defines its direct DEX pair edge. The exchange internally routes sibling swaps through their shared parent.

```
PathUSD (0x20C0...0000) — root (quoteToken = address(0))
├── AlphaUSD (0x20C0...0001)
├── BetaUSD  (0x20C0...0002)
└── ThetaUSD (0x20C0...0003)
```

### Reference swaps

- **Parent (direct edge)**: Alpha → PathUSD — **112,501 gas** (1 hop)
- **Sibling (shared parent)**: Alpha → Beta — **152,200 gas** (2 hops: Alpha → Path → Beta)

### 1-Hop Comparison (Alpha → PathUSD)

A single edge in the DEX tree.

- **Direct Tempo Exchange**: **112,501**
- **Uniswap V4 Hook**: **728,679**
- **V4 overhead**: +616,178 (6.5x)

### 2-Hop Comparison (Alpha → PathUSD → Beta)

Two edges in the DEX tree, executed as a single transaction.

- **Tempo native sibling swap (internal routing)**: **152,200**
- **Direct Tempo via router contract (2 explicit exchange calls)**: **1,485,331**
- **Uniswap V4 Hook (2 pools, single `unlock`)**: **1,350,425**

The Tempo precompile handles the 2-hop sibling swap internally for just 152,200 gas, only ~40k more than a 1-hop, because the intermediate token never leaves the precompile.

When the same 2-hop is decomposed into explicit calls (either via a router contract or V4), V4 is ~135k cheaper than two explicit Tempo exchange calls because the intermediate token's delta nets to zero in V4's accounting and never transfers as an ERC20.

### Marginal cost per additional hop

- **Direct Tempo (native)**: 1-hop 112,501 → 2-hop 152,200 (**+39,699**)
- **V4 Hook**: 1-hop 728,679 → 2-hop 1,350,425 (**+621,746**)

## Hook Seeding Optimization

Pre-seeding the aggregator hook with 1 unit (0.000001) of each token it will handle eliminates cold `SSTORE` operations during the first swap, saving significant gas.

### Why it works

ERC20 `balanceOf` storage slots use the following gas costs for `SSTORE`:

| Transition                          | Gas cost   |
| ----------------------------------- | ---------- |
| Zero → non-zero (cold `SSTORE`)     | **20,000** |
| Non-zero → non-zero (warm `SSTORE`) | **5,000**  |

When the hook receives tokens via `poolManager.take()` during `beforeSwap`, an unseeded hook pays 20k gas per token (zero → non-zero balance). A seeded hook pays only 5k (non-zero → non-zero), saving ~15k per token transfer. Combined with the output token transfer back to PoolManager, the savings compound.

### Measured savings

| Scenario                 | Gas saved  | % reduction |
| ------------------------ | ---------- | ----------- |
| Input token seeded only  | **24,403** | ~14%        |
| Output token seeded only | **24,403** | ~14%        |
| Both tokens seeded       | **48,803** | ~28%        |

## Swap Flow

### Exact-Input Swap

```
User → Router → PoolManager.swap(key, params)
                       │
                       ▼
              Hook._beforeSwap()
                       │
              ┌────────┴─────────┐
              │ _internalSettle  │
              │   │              │
              │   ▼              │
              │ _conductSwap     │
              │   │              │
              │   ├─ poolManager.take(tokenIn)     // pull input from PM
              │   ├─ TEMPO.swapExactAmountIn(...)  // execute on Tempo
              │   ├─ poolManager.sync(tokenOut)    // prepare output
              │   ├─ transfer tokenOut → PM        // send output to PM
              │   └─ poolManager.settle()          // finalize
              └──────────────────┘
                       │
                       ▼
              Return BeforeSwapDelta
              (cancels core pool swap,
               substitutes Tempo result)
```

### Exact-Output Swap

Same flow, but:

1. Queries `tempoExchange.quoteSwapExactAmountOut` first to determine required input.
2. Takes the quoted input amount from the PoolManager.
3. Executes `tempoExchange.swapExactAmountOut` on Tempo.

### Delta Mechanics

The hook returns a `BeforeSwapDelta` that fully replaces the Uniswap V4 core swap:

- `specified` delta cancels the core pool's swap (`-params.amountSpecified`)
- `unspecified` delta communicates the actual output (or input) from Tempo

This means the V4 pool's internal AMM state (sqrtPrice, ticks, etc.) is never used. The pool is an empty shell. All pricing and execution come from Tempo.

## Technical Details

### Amount Precision

Tempo uses `uint128` for all token amounts. The hook converts between Uniswap's `uint256` and Tempo's `uint128` with overflow protection:

```solidity
function _safeToUint128(uint256 value) internal pure returns (uint128) {
    if (value > type(uint128).max) revert AmountExceedsUint128();
    return uint128(value);
}
```

In practice, this is not a concern for stablecoins with 6 decimals. The `uint128` type supports values up to ~340 trillion tokens.

### Hook Permissions

The hook requires three permissions, encoded in the hook address:

- `BEFORE_SWAP`: Intercept swaps to route through Tempo
- `BEFORE_SWAP_RETURNS_DELTA`: Return custom deltas that replace the core swap
- `BEFORE_INITIALIZE`: Validate token pairs during pool creation

### Hook Address ID

The hook address prefix `71` identifies it as a TempoExchange aggregator (see the ID system in `../src/aggregator-hooks/README.md`). This is enforced during CREATE2 deployment via salt mining with `HookMiner`.

### Deployment

The hook is deployed via CREATE2 with a mined salt that produces an address with the correct permission bits and `71` prefix. Pool initialization is done by calling `PoolManager.initialize()` with a `PoolKey` referencing the hook address.

```
Deploy: CREATE2 → TempoExchangeAggregator (singleton)
Register pairs: PoolManager.initialize(poolKey) for each supported pair
```

### Chain Context

- **Chain**: Tempo (EVM-compatible L1/L2)
- **Exchange**: Precompile at `0xDEc0000000000000000000000000000000000000`
- **Token decimals**: 6 (all Tempo stablecoins)
- **PoolManager**: Standard Uniswap V4 PoolManager deployed on Tempo

## Deployment

### Moderato Testnet (chain 42431)

**Deployed addresses:**

- Hook: `0x480517265Fb617Bb98b95745C5599acE71b92088`
- Router: `0x82bbA04181082fB860D3B1D08543C383f5FE7a8b`
- PoolManager: `0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2`

### Deploying

1. **Fund wallet** — Tempo uses PathUSD for gas. Fund via RPC:

   ```bash
   curl -X POST https://rpc.moderato.tempo.xyz \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","method":"tempo_fundAddress","params":["YOUR_ADDRESS"],"id":1}'
   ```

2. **Mine salt** (if deploying fresh):

   ```bash
   forge script script/DeployTempoAggregator.s.sol --sig "mineSalt()" --rpc-url tempo_testnet
   ```

3. **Deploy**:

   ```bash
   HOOK_SALT=<salt> forge script script/DeployTempoAggregator.s.sol \
     --rpc-url https://rpc.moderato.tempo.xyz --broadcast --skip-simulation
   ```

4. **Initialize pools**:
   ```bash
   HOOK_ADDRESS=<hook> ROUTER_ADDRESS=<router> \
   forge script script/InitializeTempoPools.s.sol \
     --rpc-url https://rpc.moderato.tempo.xyz --broadcast --skip-simulation
   ```
