# SwapSimulator
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0c68c6912ec9b3df692fd62740997db52f245b7d/src/alf/libraries/SwapSimulator.sol)

**Title:**
SwapSimulator

**Author:**
Uniswap Labs

View-only library that replicates Pool.sol's tick-walking swap loop using
external state reads via StateLibrary.extsload(). Produces indicative quotes
that closely match actual swap execution for a given fee override.

**Note:**
security-contact: security@uniswap.org


## State Variables
### MAX_WALK_STEPS
Hard cap on `_walkTicks` iterations. Bounds the worst-case gas for pathological
scenarios (unseeded pool, oversized swap walking past LP into empty tick space,
sparse-bitmap walks) regardless of whether the caller honors `BaseALFHook.maxGas`.
The loop exits early on `amountRemaining == 0` or hitting the price limit; this
cap only fires for runaway walks.
4_096 covers every legitimate use of the library:
- SpreadQuoter single-band: <10 steps
- DualPoolHook 8-bucket distributions at typical spacings: <100 steps
- Extreme wide-bucket configs spanning many bitmap words: still well under
while still bounding the worst case to ~20M gas at ~5K gas/iter (well under one
block, so an on-chain caller without a `{gas:}` envelope OOGs the call, not the
block). Hitting the cap returns the partial output computed so far; for a quote
consumer this surfaces as a smaller-than-expected output, which the caller can
detect via slippage bounds.


```solidity
uint256 internal constant MAX_WALK_STEPS = 4_096
```


## Functions
### simulateSwap

Simulate a swap against a v4 pool's current state.


```solidity
function simulateSwap(
    IPoolManager manager,
    PoolId poolId,
    bool zeroForOne,
    int256 amountSpecified,
    uint24 lpFeePips,
    int24 tickSpacing
) internal view returns (uint256 result);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`manager`|`IPoolManager`|The PoolManager contract.|
|`poolId`|`PoolId`|The pool to simulate against.|
|`zeroForOne`|`bool`|The swap direction.|
|`amountSpecified`|`int256`|Negative for exact input, positive for exact output.|
|`lpFeePips`|`uint24`|The LP fee to apply (same as the hook's fee override).|
|`tickSpacing`|`int24`|The pool's tick spacing.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`result`|`uint256`|For exact input: total output amount. For exact output: total input required.|


### simulateSwapToPrice

Simulate a swap up to a target price, returning both amounts.

Walks ticks until the price limit is reached or the specified amount is exhausted.
Mirrors Pool.sol's swap loop with protocol fee handling.
Soft-fail contract: returns `(0, 0)` -- never reverts -- for every input shape
`Pool.swap` would reject with `PriceLimitAlreadyExceeded` or `PriceLimitOutOfBounds`.
Routers and aggregators that take the output at face value can rely on the
invariant `(amountIn, amountOut) == (0, 0)` ⇔ "untradable at these parameters".
Pre-loop rejection cases:
- uninitialized pool (`slot0.sqrtPriceX96 == 0`)
- `amountSpecified == 0`
- `sqrtPriceLimitX96` on the wrong side of the current price for the chosen
direction (no swap can move price toward the limit)
- `sqrtPriceLimitX96` at or past `MIN_SQRT_PRICE` / `MAX_SQRT_PRICE`
(`Pool.swap` rejects the boundary value strictly)
Post-loop rejection case:
- cumulative `amountCalc` or `(amountSpecified - amountRemaining)` exceeds
`int128` range. Mirrors `Pool.swap`'s final `toInt128()` cast which would
`SafeCastOverflow()` -- triggerable with fees near `MAX_LP_FEE`, an aggressive
correct-side limit, and the price already adjacent to the limit.


```solidity
function simulateSwapToPrice(
    IPoolManager manager,
    PoolId poolId,
    bool zeroForOne,
    int256 amountSpecified,
    uint24 lpFeePips,
    int24 tickSpacing,
    uint160 sqrtPriceLimitX96
) internal view returns (uint256 amountIn, uint256 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`manager`|`IPoolManager`|The PoolManager contract.|
|`poolId`|`PoolId`|The pool to simulate against.|
|`zeroForOne`|`bool`|The swap direction.|
|`amountSpecified`|`int256`|Negative for exact input, positive for exact output.|
|`lpFeePips`|`uint24`|The LP fee to apply (same as the hook's fee override).|
|`tickSpacing`|`int24`|The pool's tick spacing.|
|`sqrtPriceLimitX96`|`uint160`|The target price. Swap terminates when this price is reached or the specified amount is exhausted, whichever comes first.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Total input consumed (including fees).|
|`amountOut`|`uint256`|Total output received.|


### _walkTicks

Core tick-walking loop — mirrors Pool.sol. Modifies `s` in place.
Extracted from the main function to stay within stack depth limits.
Gas hotspots by impact:
- Highest: per-iteration next-tick lookup and bitmap masking.
- Medium: step accumulation and tick-cross liquidity updates.
- Lower: per-iteration bounds checks and branch bookkeeping.


```solidity
function _walkTicks(
    IPoolManager manager,
    PoolId poolId,
    SwapState memory s,
    bool zeroForOne,
    uint24 feePips,
    int24 tickSpacing,
    bool exactInput
) private view;
```

### _stepAndAccumulate

Execute one swap step: compute amounts via SwapMath and accumulate into state.
Separated from the main loop to stay within stack depth limits while allowing
the caller to cache sqrtPriceNextX96.


```solidity
function _stepAndAccumulate(SwapState memory s, uint160 sqrtPriceTargetX96, uint24 feePips, bool exactInput)
    private
    pure
    returns (uint160 sqrtPriceStartX96);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sqrtPriceStartX96`|`uint160`|The price before the step (for boundary detection).|


### _addLiquidityDelta

Equivalent overflow semantics to v4-core LiquidityMath.addDelta.


```solidity
function _addLiquidityDelta(uint128 x, int128 y) private pure returns (uint128 z);
```

### _nextInitializedTick

Find the next initialized tick using external bitmap reads.


```solidity
function _nextInitializedTick(IPoolManager manager, PoolId poolId, int24 tick, int24 tickSpacing, bool lte)
    private
    view
    returns (int24 next, bool initialized);
```

## Errors
### InvalidLpFeePips
`lpFeePips` exceeds `SwapMath.MAX_SWAP_FEE` (1e6). Forwarding such a value into
`SwapMath.computeSwapStep`'s unchecked body would underflow `MAX_SWAP_FEE - fee`
and produce either an empty revert at `FullMath.mulDiv`'s overflow guard
(exact-input path with large amounts) or a numerically meaningless quote
equivalent to a 0% fee swap (smaller amounts, exact-output path). Reverting
cleanly here gives callers an unambiguous diagnostic.


```solidity
error InvalidLpFeePips(uint24 supplied);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`supplied`|`uint24`|The invalid fee value the caller passed.|

## Structs
### SwapState

```solidity
struct SwapState {
    uint160 sqrtPriceX96;
    int24 tick;
    uint128 liquidity;
    int256 amountRemaining;
    int256 amountCalc;
    uint160 sqrtPriceLimitX96;
}
```

