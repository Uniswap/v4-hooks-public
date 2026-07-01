# unbackedClaims
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

The portion of the bucket's claims the PoolManager cannot physically honor yet.

Claims whose backing settle is still pending this tx. Returns 0 in the common,
fully-backed case. Reads the PoolManager's balance (`pm`), not the consumer's, so it has
no `address(this)` dependency.


```solidity
function unbackedClaims(Inventory storage self, bytes32 bucket, Currency currency, IPoolManager pm)
view
returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|    Capability storage.|
|`bucket`|`bytes32`|  The accounting partition to inspect.|
|`currency`|`Currency`|The underlying asset of the claims.|
|`pm`|`IPoolManager`|      The v4 PoolManager whose balance bounds the backed portion.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The unbacked claim amount (token's native decimals).|


