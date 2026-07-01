# checkUnlocked
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Revert {DepositLocked} if `user`'s deposit lock has not elapsed on the consumer's clock.

The lock spans `[lastDepositBlock, lastDepositBlock + minBlocks)`. `minBlocks == 0`
disables the lock (same-block deposit-then-withdraw allowed); `1` reproduces a
same-block ban; `N > 1` enforces an `N`-block hold.


```solidity
function checkUnlocked(Shares storage self, VaultId vaultId, address user, uint64 minBlocks, uint256 nowBlock) view;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|     Shares ledger storage.|
|`vaultId`|`VaultId`|  The vault to check.|
|`user`|`address`|     The holder whose last-deposit block gates the withdrawal.|
|`minBlocks`|`uint64`|The lock duration in the consumer's clock blocks.|
|`nowBlock`|`uint256`| The current block on the consumer's clock.|


