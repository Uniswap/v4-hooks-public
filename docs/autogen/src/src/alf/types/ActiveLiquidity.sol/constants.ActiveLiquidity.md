# Constants
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/ActiveLiquidity.sol)

### ACTIVE_LIQUIDITY_NAMESPACE
Transient-storage namespace seed for the active per-bucket JIT liquidity array. Combined
with a `PoolId` to derive a per-pool base slot; see {activeLiquidityFor}.


```solidity
bytes32 constant ACTIVE_LIQUIDITY_NAMESPACE = keccak256("dualpoolhook.activeliq.v1")
```

