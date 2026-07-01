# LiquidityBucket
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Distribution.sol)

A tick range with a weight for liquidity distribution.


```solidity
struct LiquidityBucket {
int24 tickLower;
int24 tickUpper;
uint16 weightBps;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`tickLower`|`int24`|Lower tick boundary (aligned to the pool's tickSpacing).|
|`tickUpper`|`int24`|Upper tick boundary (aligned to the pool's tickSpacing).|
|`weightBps`|`uint16`|Fraction of total capital allocated to this range, in basis points. All weights across a pool's distribution sum to `TOTAL_WEIGHT_BPS`.|

