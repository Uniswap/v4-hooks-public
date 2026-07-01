# InvalidDistribution
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Distribution.sol)

Distribution is invalid: empty, exceeds `MAX_BUCKETS`, weights do not sum to
`TOTAL_WEIGHT_BPS`, or a bucket has zero weight.


```solidity
error InvalidDistribution();
```

