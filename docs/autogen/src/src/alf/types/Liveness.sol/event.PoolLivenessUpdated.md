# PoolLivenessUpdated
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Liveness.sol)

Emitted when a pool's liveness flag changes.


```solidity
event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose liveness changed.|
|`isLive`|`bool`|The new liveness state.|

