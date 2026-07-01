# earned
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Rewards `user` could claim right now, given their current balance and the supply.


```solidity
function earned(
Rewards storage self,
VaultId id,
address user,
uint256 userShares,
uint256 totalSupply,
uint256 nowBlock
) view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Rewards`|       Capability storage.|
|`id`|`VaultId`|         The vault to read.|
|`user`|`address`|       The account to value.|
|`userShares`|`uint256`| `user`'s current share balance.|
|`totalSupply`|`uint256`|The current total share supply.|
|`nowBlock`|`uint256`|   The consumer's current block (from `_getBlockNumberish()`).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The claimable reward amount (reward token's native decimals).|


