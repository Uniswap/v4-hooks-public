# jitLockFor
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/JITLock.sol)

Derive the per-pool JIT lock for `poolId`.

One keccak per pool. Per-pool scoping is required so cross-pool reentry cannot clear
pool A's lock when pool B's `afterSwap` runs.


```solidity
function jitLockFor(PoolId poolId) pure returns (JITLock);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose lock slot to address.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`JITLock`|The per-pool transient lock.|


