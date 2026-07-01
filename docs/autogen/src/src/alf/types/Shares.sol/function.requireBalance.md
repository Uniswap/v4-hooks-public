# requireBalance
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Revert {InsufficientShares} unless `user` holds at least `shares`.


```solidity
function requireBalance(Shares storage self, VaultId vaultId, address user, uint256 shares) view;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|   Shares ledger storage.|
|`vaultId`|`VaultId`|The vault to check.|
|`user`|`address`|   The holder whose balance gates the burn.|
|`shares`|`uint256`| The share count the caller intends to burn.|


