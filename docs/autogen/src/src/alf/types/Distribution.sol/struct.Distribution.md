# Distribution
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Distribution.sol)

**Title:**
Distribution

**Author:**
Uniswap Labs

Per-pool JIT liquidity distribution as a type-driven value: the bucket set plus its
validation. A hook holds a `Distribution` storage field, configures it via {set}, and
reads the buckets via {get}. The pure allocation math ({computeAllocations},
{activeLiquidity}) is provided as free functions over a `LiquidityBucket[] memory`, so
the hook fetches the buckets once and runs both the sizing math and its own
`modifyLiquidity` deploy/remove loop against the same array.

**Note:**
security-contact: security@uniswap.org


```solidity
struct Distribution {
mapping(PoolId poolId => LiquidityBucket[]) _inner;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`_inner`|`mapping(PoolId poolId => LiquidityBucket[])`|The bucket list per pool.|

