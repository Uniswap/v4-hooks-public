# mint
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Mint `shares` to `to` and stamp their deposit block. Increments both the total and the
holder balance. The consumer must have already verified the vault is bootstrapped.


```solidity
function mint(Shares storage self, VaultId vaultId, address to, uint256 shares, uint256 nowBlock) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|   Shares ledger storage.|
|`vaultId`|`VaultId`|The vault receiving the mint.|
|`to`|`address`|     The account credited with the minted shares.|
|`shares`|`uint256`| The share count to mint.|
|`nowBlock`|`uint256`|The current block on the consumer's clock, stamped as the last deposit.|


