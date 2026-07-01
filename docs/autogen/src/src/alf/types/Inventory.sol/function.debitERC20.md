# debitERC20
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

Debit `amount` from the bucket's raw ERC-20 after a PM settlement.

The `_settle` itself is the consumer's responsibility; this only updates the per-bucket
counter. Reverts {InsufficientPoolBalance} if the bucket is short.


```solidity
function debitERC20(Inventory storage self, bytes32 bucket, uint256 amount) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to debit.|
|`amount`|`uint256`|The raw amount settled away (token's native decimals).|


