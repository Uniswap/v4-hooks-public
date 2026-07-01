# Constants
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Distribution.sol)

### MAX_BUCKETS
Maximum buckets per pool. Bounds the JIT cycle's gas: each bucket costs one
`modifyLiquidity` to deploy and one to remove, so cost scales linearly with the count.


```solidity
uint8 constant MAX_BUCKETS = 8
```

### TOTAL_WEIGHT_BPS
Basis-points denominator for distribution weights. Every pool's `weightBps` values sum to
this, and it is the divisor when pro-budgeting each bucket's slice of the pool balance.


```solidity
uint256 constant TOTAL_WEIGHT_BPS = 10_000
```

