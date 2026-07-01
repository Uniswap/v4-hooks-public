# PoolNotLive
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Liveness.sol)

A live-gated operation (a swap) ran on a paused pool. Pools default to paused after
`manager.initialize`; the owner enables a pool via its `setPoolLive` entry point.


```solidity
error PoolNotLive(PoolId poolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose live flag is currently false.|

