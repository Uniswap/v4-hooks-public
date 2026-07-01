# erc20Of
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

Raw ERC-20 attributed to this bucket.


```solidity
function erc20Of(Inventory storage self, bytes32 bucket) view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The raw ERC-20 balance (token's native decimals) attributed to the bucket.|


