# set
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Distribution.sol)

Validate and store a liquidity distribution for `poolId`. Enforces 1 to `MAX_BUCKETS`
entries, tickSpacing-aligned ranges within the `TickMath` range, no zero-weight bucket,
and weights summing to exactly `TOTAL_WEIGHT_BPS`.


```solidity
function set(Distribution storage self, PoolId poolId, LiquidityBucket[] calldata buckets, int24 tickSpacing) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Distribution`|       Distribution storage.|
|`poolId`|`PoolId`|     The pool to configure.|
|`buckets`|`LiquidityBucket[]`|    The distribution buckets to validate and store.|
|`tickSpacing`|`int24`|The pool's tick spacing, for alignment validation.|


