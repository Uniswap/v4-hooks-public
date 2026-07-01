# assetPair
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

The asset pair bound to a vault at bootstrap.


```solidity
function assetPair(Shares storage self, VaultId vaultId) view returns (Assets memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|   Shares ledger storage.|
|`vaultId`|`VaultId`|The vault to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`Assets`|The `(asset0, asset1)` pair (zero addresses if never bootstrapped).|


