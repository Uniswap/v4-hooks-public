# sharesOf
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

ERC-4626 shares this bucket owns.


```solidity
function sharesOf(Inventory storage self, bytes32 bucket) view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The vault share count held for the bucket.|


