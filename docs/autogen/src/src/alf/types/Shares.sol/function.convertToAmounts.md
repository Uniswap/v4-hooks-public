# convertToAmounts
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Convert a share count to the equivalent two-asset amounts at the supplied balances,
applying the virtual-shares offset. Deposits round up (depositor pays slightly more,
preventing dilution); withdrawals round down (withdrawer receives slightly less,
preventing over-withdrawal at remaining holders' expense).

The consumer supplies `bal0`/`bal1` (the total managed balance per asset) because the
balance sources live outside this type. Reverts {VaultNotBootstrapped} when the supply
is zero: a pre-bootstrap vault has no defined ratio.


```solidity
function convertToAmounts(
Shares storage self,
VaultId vaultId,
uint256 bal0,
uint256 bal1,
uint8 offset,
uint256 shares,
bool roundUp
) view returns (uint256 amount0, uint256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|   Shares ledger storage.|
|`vaultId`|`VaultId`|The vault whose supply sets the denominator.|
|`bal0`|`uint256`|   Total managed asset0 balance.|
|`bal1`|`uint256`|   Total managed asset1 balance.|
|`offset`|`uint8`| Virtual-shares decimal offset for the inflation defense.|
|`shares`|`uint256`| The share count to convert.|
|`roundUp`|`bool`|True to round up (deposit), false to round down (withdraw).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|The asset0 amount equivalent to `shares`.|
|`amount1`|`uint256`|The asset1 amount equivalent to `shares`.|


