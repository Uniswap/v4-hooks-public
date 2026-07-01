# creditBootstrap
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Credit the full bootstrap supply to `to` and stamp their deposit block. Sets both the
total and the holder balance to `sharesMinted` (a bootstrap mints into an empty vault).


```solidity
function creditBootstrap(Shares storage self, VaultId vaultId, address to, uint256 sharesMinted, uint256 nowBlock) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|        Shares ledger storage.|
|`vaultId`|`VaultId`|     The vault being bootstrapped.|
|`to`|`address`|          The account credited with the bootstrap shares.|
|`sharesMinted`|`uint256`|The bootstrap shares to credit.|
|`nowBlock`|`uint256`|    The current block on the consumer's clock, stamped as the last deposit.|


