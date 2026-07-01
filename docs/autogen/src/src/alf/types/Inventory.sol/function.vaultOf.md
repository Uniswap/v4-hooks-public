# vaultOf
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

The ERC-4626 vault bound to `bucket`, or `address(0)` if held as raw ERC-20.


```solidity
function vaultOf(Inventory storage self, bytes32 bucket) view returns (IERC4626);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IERC4626`|The vault bound to the bucket, or the zero vault if none.|


