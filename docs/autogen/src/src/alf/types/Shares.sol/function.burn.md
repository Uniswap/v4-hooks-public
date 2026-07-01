# burn
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Burn `shares` from `from`, decrementing both the total and the holder balance.

Does not range-check `shares`; the consumer calls {requireBalance} first so the
decrement cannot underflow, matching the holder-balance invariant
(`userShares <= totalShares`).


```solidity
function burn(Shares storage self, VaultId vaultId, address from, uint256 shares) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|   Shares ledger storage.|
|`vaultId`|`VaultId`|The vault the burn debits.|
|`from`|`address`|   The account whose shares are burned.|
|`shares`|`uint256`| The share count to burn.|


