# totalSupply
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Real shares outstanding for a vault, across all holders. Excludes the virtual shares
that {convertToAmounts} adds for inflation defense.


```solidity
function totalSupply(Shares storage self, VaultId vaultId) view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|   Shares ledger storage.|
|`vaultId`|`VaultId`|The vault to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The real share supply.|


