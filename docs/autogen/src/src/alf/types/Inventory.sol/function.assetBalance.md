# assetBalance
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

Gross managed balance: raw + claims + `convertToAssets(shares)`.

The vault leg is the true per-share economic value, ignoring exit fees or temporary
throttles. Used by LP share math so claims are over true economic stake. Contrast
{effectiveBalance}, which sizes the vault leg via `previewRedeem`.


```solidity
function assetBalance(Inventory storage self, bytes32 bucket) view returns (uint256 bal);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to value.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`bal`|`uint256`|The gross managed balance (token's native decimals).|


