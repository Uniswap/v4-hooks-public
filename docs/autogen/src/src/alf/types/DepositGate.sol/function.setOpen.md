# setOpen
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/DepositGate.sol)

Set `poolId`'s deposit gate and emit {ExternalDepositsUpdated}.


```solidity
function setOpen(DepositGate storage self, PoolId poolId, bool enabled) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`DepositGate`|   DepositGate storage.|
|`poolId`|`PoolId`| The pool to toggle.|
|`enabled`|`bool`|The new gate state.|


