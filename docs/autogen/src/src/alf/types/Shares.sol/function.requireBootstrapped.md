# requireBootstrapped
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Revert {VaultNotBootstrapped} unless the vault has shares.


```solidity
function requireBootstrapped(Shares storage self, VaultId vaultId) view;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|   Shares ledger storage.|
|`vaultId`|`VaultId`|The vault to check.|


