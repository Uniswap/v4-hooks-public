# SmartPool: Integration Guide for Aggregators & Routers

**Audience:** third-party aggregators, routers, solvers, and quote APIs that want to
source liquidity from `SmartPoolHook` pools.

**Source of truth:** [src/alf/SmartPoolHook.sol](../../src/alf/SmartPoolHook.sol),
[src/alf/base/SmartPoolBase.sol](../../src/alf/base/SmartPoolBase.sol), and
[src/alf/interfaces/IALFHook.sol](../../src/alf/interfaces/IALFHook.sol). This guide
is the integration-facing companion to the internal *SmartPool Deep Dive* and the
[ALF design doc](./alf-design.md). Where this guide and older prose disagree, the
contract wins.

---

## 1. TL;DR — what you actually have to do

1. **Detect** a SmartPool pool: its `PoolKey.hooks` address returns `true` for
   `supportsInterface(type(IALFHook).interfaceId)` and carries the
   `beforeSwap`/`afterSwap`/`beforeInitialize`/`before{Add,Remove}Liquidity` permission bits.
2. **Quote** using the `IALFHook` views — **never** the pool's on-chain liquidity.
   A SmartPool holds **zero persistent v4 liquidity between swaps**; `getSlot0` shows a
   price but `getLiquidity` is ~0. Use `getIndicativeQuote` / `swapToPrice` /
   `getEffectiveLiquidity`.
3. **Execute** a completely ordinary v4 swap (PoolManager `unlock`+`swap`, or the
   Universal Router v4 actions). No special calldata. `hookData` is ignored.
4. **Handle the two failure modes you care about:** a paused pool reverts
   `PoolNotLive(poolId)` on execution and returns `0` from the quote views; and
   *effective* liquidity can be below *total* reserves when the operator's vault is
   throttled. Size fills against effective liquidity.

If your stack already trades vanilla v4 hooked pools, the execution path is unchanged.
The only new work is **quoting through the hook views instead of pool state**.

---

## 2. Mental model: what a SmartPool pool looks like from outside

A SmartPool pool is a standard Uniswap v4 pool whose `hooks` address is a deployed
`SmartPoolHook`. Operationally it differs from a normal pool in three ways that matter
to a router:

| Property | Normal v4 pool | SmartPool pool |
|---|---|---|
| Persistent liquidity | Sits in the pool 24/7 | **~0 between swaps.** Liquidity is deployed just-in-time inside `beforeSwap` and removed in `afterSwap` ([SmartPoolHook.sol:658-687](../../src/alf/SmartPoolHook.sol#L658-L687)) |
| Where inventory lives | In the PoolManager | In ERC-4626 vaults (rehypothecated) + ERC-6909 claims + tracked ERC-20, owned by the hook |
| Fee | `PoolKey.fee`, possibly dynamic | `PoolKey.fee`, **static and immutable**, never dynamic |

Because liquidity is JIT, **on-chain pool depth is not a routing signal.** Capacity is
discovered through the hook's `IALFHook` views, which report what the hook can actually
withdraw from its vaults and deploy *right now*.

Each swap, atomically:
`beforeSwap` redeems claims → withdraws only the shortfall from vaults → deploys
concentrated LP across the operator's tick "buckets" → v4 executes the swap at the
static `key.fee` → `afterSwap` tears the positions down, settles deltas, and re-vaults
the remainder. The swapper sees a normal swap and a normal `BalanceDelta`.

---

## 3. Discovery & identification

There is no shared registry. Discover pools through your own tracking (initialization
events, indexers, operator onboarding), then confirm the hook is a SmartPool:

```solidity
// 1. ERC-165: the hook implements the ALF view interface.
bool isAlf = IERC165(key.hooks).supportsInterface(type(IALFHook).interfaceId);

// 2. Hook permission bits encoded in the hook address (v4 convention).
//    SmartPool requires: beforeInitialize, beforeAddLiquidity, beforeRemoveLiquidity,
//    beforeSwap, afterSwap. All *ReturnDelta flags are false.
//    See getHookPermissions() — SmartPoolHook.sol:600.
```

A pool that passes (1) is an ALF hook; SmartPool is one ALF strategy among several
(spread quoters, etc.). You do not need to distinguish SmartPool specifically — the
`IALFHook` surface is uniform. If you want to, SmartPool-only signals include the
presence of `livePools(poolId)`, `getDistribution(poolId)`, and `getReserves` returning
non-zero values.

> Do not hardcode hook addresses from this doc — there are none here. Pull deployed
> addresses from your deployment registry and verify with `cast code` before use.

---

## 4. The quote surface (`IALFHook`)

All five methods are `view` and intended to be called via `staticcall`. Full interface:
[IALFHook.sol](../../src/alf/interfaces/IALFHook.sol).

| Method | Returns | Use it for |
|---|---|---|
| `getIndicativeQuote(key, zeroForOne, amountSpecified, hookData)` | `outputAmount` | Single-number indicative for ranking / EV models |
| `swapToPrice(key, zeroForOne, amountSpecified, sqrtPriceLimitX96, hookData)` | `(amountIn, amountOut)` | Price-bounded fill simulation for **split planning** |
| `getReserves(key)` | `(token0, token1)` | True TVL under management (economic) |
| `getEffectiveLiquidity(key)` | `(token0, token1)` | **Immediately swappable** liquidity (size fills against this) |
| `isLive()` | `bool` | Hook-level liveness — see the caveat below |
| `maxGas()` | `uint32` | Cap your `staticcall` gas to this value |

### 4.1 Sign & return conventions

`amountSpecified` follows v4's `SwapParams` convention:

- **Exact input** → `amountSpecified < 0`. `getIndicativeQuote` returns the **expected
  output**. ([SmartPoolHook.sol:562](../../src/alf/SmartPoolHook.sol#L562))
- **Exact output** → `amountSpecified > 0`. `getIndicativeQuote` returns the **required
  input**.
- `swapToPrice` always returns `(amountIn, amountOut)` in token terms regardless of
  direction; both are inclusive of fees (`amountIn` includes the fee component).

`zeroForOne = true` swaps `currency0 → currency1`.

### 4.2 `hookData` is ignored — pass empty bytes

SmartPool is a static-pricing strategy. `beforeSwap`, `getIndicativeQuote`, and
`swapToPrice` **ignore `hookData` entirely** ([SmartPoolHook.sol:67](../../src/alf/SmartPoolHook.sol#L67)).
There are no attestations, signed curves, or per-swap discounts. Pass `""`. (Passing a
populated `ALFHookData` is harmless but has no effect.)

### 4.3 A `0` quote means "skip me"

Per the `IALFHook` contract, the views never revert under normal conditions — they
return `0` when the hook can't price the swap. SmartPool returns `(0, …)` when:

- the pool is **not live** (`livePools[poolId] == false`),
- effective balances are zero (un-bootstrapped, or vault fully throttled), or
- `slot0` price is zero / `amountSpecified == 0`.

See [`_simulateIndicative`](../../src/alf/SmartPoolHook.sol#L955-L991). Treat a `0`
indicative as an explicit "do not route here right now."

### 4.4 Cap gas with `maxGas()`

`getIndicativeQuote`/`swapToPrice` are bounded view computations (a single swap step
over the active buckets), but you should still cap `staticcall` gas to `maxGas()`. A
hook that exceeds its declared budget should be deprioritized — that's the ALF
convention.

---

## 5. Reading the fee

The fee is **static** and set at pool creation. Read it directly — no per-swap fee
discovery needed:

- From the `PoolKey` you already hold: `key.fee` (a concrete `uint24`, **never** the
  dynamic-fee flag `0x800000` — SmartPool rejects dynamic-fee pools at init,
  [SmartPoolHook.sol:298](../../src/alf/SmartPoolHook.sol#L298)).
- Or from `StateLibrary.getSlot0(poolId).lpFee` — since the fee is non-dynamic this
  reflects `key.fee` directly.

The protocol fee (if any) is composed into the indicative quote automatically
([`_composeEffectiveFee`](../../src/alf/SmartPoolHook.sol#L993-L996)), so `getIndicativeQuote`
already reflects LP fee + protocol fee. You do not need to re-apply either.

---

## 6. Reserves vs. effective liquidity — size against *effective*

This is the one accounting subtlety that affects fill sizing.

- `getReserves` = **total economic assets**: `vault.convertToAssets(shares)` +
  PoolManager claims + tracked ERC-20. This is what LPs own.
- `getEffectiveLiquidity` = **what the hook can withdraw and deploy this block**:
  `min(convertToAssets, pro-rata maxWithdraw)` + claims + ERC-20
  ([SmartPoolHook.sol:542-549](../../src/alf/SmartPoolHook.sol#L542-L549)).

When the operator's ERC-4626 vault is paused, capped, or utilization-constrained,
`getEffectiveLiquidity < getReserves`. The JIT cycle and the quote path both size
against **effective** liquidity, so a swap larger than effective liquidity will simply
fill less (or, near the ceiling, the cycle reverts on the vault withdraw). **Plan
fills against `getEffectiveLiquidity`, not `getReserves`.** `swapToPrice` already does
this internally, so prefer it for split planning.

---

## 7. Execution: a normal v4 swap

There is nothing SmartPool-specific in the execution path. Swap as you would against
any v4 pool:

- **Via PoolManager:** `unlock` → `swap(key, params, "")` → settle/take deltas.
- **Via Universal Router:** standard v4 `SWAP_EXACT_IN` / `SWAP_EXACT_OUT` actions with
  `SETTLE`/`TAKE`.

```solidity
SwapParams memory params = SwapParams({
    zeroForOne: zeroForOne,
    amountSpecified: amountSpecified,        // <0 exact-in, >0 exact-out
    sqrtPriceLimitX96: yourPriceLimit        // your slippage bound
});
// hookData = "" — ignored by SmartPool
BalanceDelta delta = poolManager.swap(key, params, "");
```

Notes:

- **Slippage:** enforce it the normal way — `sqrtPriceLimitX96` and a min-out / max-in
  check on the resulting `BalanceDelta`. The hook does not add slippage protection for you.
- **Native ETH is unsupported.** SmartPool rejects `address(0)` currencies at init
  ([SmartPoolHook.sol:293](../../src/alf/SmartPoolHook.sol#L293)); pools are WETH-style.
  No `msg.value` path.
- **No callbacks into you.** SmartPool returns `ZERO_DELTA` from `beforeSwap` and `0`
  from `afterSwap` (no `*ReturnDelta` flags). Your delta is plain v4 swap math.

---

## 8. Execution via the ALF Multiplexer (optional)

If you want onchain competitive execution across several pools (a SmartPool plus other
v4/ALF pools), route through the [`ALFMultiplexer`](../../src/alf/ALFMultiplexer.sol)
instead of swapping each pool yourself. You swap against the multiplexer's virtual pool
and pass candidate pools in `hookData`:

```solidity
MultiplexerHookData memory hd = MultiplexerHookData({
    attestationData: "",                     // ignored by SmartPool candidates
    targets: [ TargetedQuoter({ poolKey: smartPoolKey, amountSpecified: 0 }), ... ],
    strictTolerancePips: 0                   // or a downside tolerance in ppm
});
poolManager.swap(multiplexerPoolKey, params, abi.encode(hd));
```

How SmartPool behaves as a candidate:

- It is detected as a **tier-1 `IALFHook` candidate** (rich path: liveness, gas budget,
  attestation, per-candidate hookData) via ERC-165
  ([ALFMultiplexer.sol:44-51](../../src/alf/ALFMultiplexer.sol#L44-L51)).
- **Autonomous mode** (`amountSpecified = 0` on every target): the multiplexer quotes
  each candidate, sorts by quote quality, and runs a greedy split fill with price limits
  derived from the next candidate's price.
- **Pre-planned mode** (any target carries a non-zero `amountSpecified`): you supply the
  split (e.g., computed off-chain from `swapToPrice`) and the multiplexer executes it in
  order.
- A **paused SmartPool reverts `PoolNotLive`**, which the multiplexer's per-target
  try/catch absorbs — that candidate is skipped and flow cascades to the next. You do
  not need to pre-filter paused pools when going through the multiplexer.

See [MultiplexerTypes.sol](../../src/alf/types/MultiplexerTypes.sol) for the encoding.

---

## 9. Failure modes & how to handle them

| Situation | What you observe | Handling |
|---|---|---|
| **Pool paused** (`setPoolLive(false)`) or not yet bootstrapped | `getIndicativeQuote`/`swapToPrice` return `0`; direct `swap` reverts `PoolNotLive(poolId)` | Skip on a `0` quote. For direct routing, read `SmartPoolHook.livePools(poolId)` to pre-filter. The multiplexer handles it via try/catch. |
| **Vault throttled** (paused/capped/high-utilization) | `getEffectiveLiquidity < getReserves`; large fills under-fill or the cycle reverts on vault withdraw | Size against `getEffectiveLiquidity` / `swapToPrice`, not `getReserves`. |
| **Quote vs. execution divergence** on large or boundary-crossing swaps | Realized output differs from `getIndicativeQuote` | See §10 — use `swapToPrice` for tighter planning; track divergence as a reputation signal. |
| **Native ETH** | Pool would never have been created with native currency | Use WETH-style pools only. |
| **`isLive()` always true** | Hook-level liveness is not per-pool | `isLive()` reports the *hook* is reachable, not that a given pool is live. Use the per-pool `livePools(poolId)` read or the `0`-quote signal for pool-level liveness. ([SmartPoolBase.sol:88-94](../../src/alf/base/SmartPoolBase.sol#L88-L94)) |

> **Liveness gating note (differs from older prose):** in the current implementation a
> pool becomes live only when the **owner calls `bootstrap`**
> ([SmartPoolHook.sol:363-377](../../src/alf/SmartPoolHook.sol#L363-L377)), not at
> `initializePool`. Between init and bootstrap, swaps revert `PoolNotLive` and quotes
> return `0`. Treat a freshly-initialized, un-bootstrapped pool as not routable.

---

## 10. Quote fidelity — what the indicative does and doesn't model

`getIndicativeQuote` and `swapToPrice` are a **compact, single-step** simulation:
they sum the liquidity of the buckets that are in range at the **current tick**, then
run **one** `SwapMath.computeSwapStep` against that constant liquidity, bounded by the
price limit ([`_simulateIndicative`](../../src/alf/SmartPoolHook.sol#L955-L991),
[`_activeIndicativeLiquidity`](../../src/alf/SmartPoolHook.sol#L998-L1029)).

Implications:

- It is **accurate for swaps that stay within the current in-range bucket set** — the
  common small/medium swap near the peg.
- It **does not tick-walk** across bucket boundaries. A large swap that crosses into or
  out of bucket ranges will see liquidity change mid-swap that the single-step quote
  doesn't capture, so the indicative can over- or under-state realized output.
- The quote uses **effective (cap-aware) assets** and the **static fee + protocol fee**,
  so it correctly reflects vault throttling and fees — the divergence is purely from the
  single-step liquidity approximation, not from fee/cap modeling.

Recommendations:

1. For ranking, `getIndicativeQuote` is fine.
2. For **split planning and tighter fills**, prefer `swapToPrice` with a real
   `sqrtPriceLimitX96` so the simulated fill is bounded the same way execution will be.
3. **Track persistent quote-vs-fill divergence per pool** and feed it into your routing
   reputation model. The ALF design explicitly expects routers to treat sustained
   divergence as a deprioritization signal rather than something the hook self-corrects.

---

## 11. Integration checklist

- [ ] Confirm hook via `supportsInterface(type(IALFHook).interfaceId)`.
- [ ] Source quotes from `getIndicativeQuote` / `swapToPrice` — **not** `getLiquidity`.
- [ ] Pass `hookData = ""`.
- [ ] Read fee from `key.fee` (or `slot0.lpFee`); reject the dynamic-fee flag (won't occur).
- [ ] Size fills against `getEffectiveLiquidity`, not `getReserves`.
- [ ] Cap `staticcall` gas to `maxGas()`.
- [ ] Treat a `0` quote as "skip"; for direct routing also check `livePools(poolId)`.
- [ ] Use only WETH-style (non-native) pools.
- [ ] Enforce your own slippage (`sqrtPriceLimitX96` + min-out/max-in).
- [ ] Track quote fidelity per pool for reputation/deprioritization.
- [ ] (Optional) Route through `ALFMultiplexer` for onchain competitive split fills.

---

## 12. Quick reference — view signatures

```solidity
// IALFHook (src/alf/interfaces/IALFHook.sol)
function getIndicativeQuote(PoolKey key, bool zeroForOne, int256 amountSpecified, bytes hookData)
    external view returns (uint256 outputAmount);          // exact-in: output; exact-out: input
function swapToPrice(PoolKey key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes hookData)
    external view returns (uint256 amountIn, uint256 amountOut);
function getReserves(PoolKey key) external view returns (uint256 token0, uint256 token1);
function getEffectiveLiquidity(PoolKey key) external view returns (uint256 token0, uint256 token1);
function isLive() external view returns (bool);            // hook-level; always true
function maxGas() external view returns (uint32);

// SmartPool-specific reads (src/alf/SmartPoolHook.sol, SmartPoolBase.sol)
mapping(PoolId => bool) public livePools;                  // authoritative per-pool liveness
function getDistribution(PoolId poolId) external view returns (LiquidityBucket[] memory);
```
