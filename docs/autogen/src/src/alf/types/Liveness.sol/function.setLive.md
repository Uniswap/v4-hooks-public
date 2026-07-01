# setLive
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Liveness.sol)

Set `poolId`'s liveness flag and emit {PoolLivenessUpdated}.


```solidity
function setLive(Liveness storage self, PoolId poolId, bool live) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Liveness`|  Liveness storage.|
|`poolId`|`PoolId`|The pool to toggle.|
|`live`|`bool`|  The new liveness state.|


