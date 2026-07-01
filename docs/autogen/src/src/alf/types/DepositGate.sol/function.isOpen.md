# isOpen
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/DepositGate.sol)

Whether `poolId` permits non-owner deposits.


```solidity
function isOpen(DepositGate storage self, PoolId poolId) view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`DepositGate`|  DepositGate storage.|
|`poolId`|`PoolId`|The pool to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|Whether non-owner deposits are currently permitted.|


