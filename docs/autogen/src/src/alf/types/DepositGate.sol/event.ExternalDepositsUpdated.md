# ExternalDepositsUpdated
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/DepositGate.sol)

Emitted when a pool's external-deposit gate changes.


```solidity
event ExternalDepositsUpdated(PoolId indexed poolId, bool enabled);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`| The pool whose gate changed.|
|`enabled`|`bool`|Whether non-owner deposits are permitted.|

