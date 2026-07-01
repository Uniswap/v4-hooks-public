# InvalidTickRange
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Distribution.sol)

A bucket's tick range is malformed: lower >= upper, outside the `TickMath` range, or not
aligned to the pool's tickSpacing.


```solidity
error InvalidTickRange();
```

