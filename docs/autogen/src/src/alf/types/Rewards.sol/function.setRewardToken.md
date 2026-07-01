# setRewardToken
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Bind the reward token for `id`.

Permanent: accrued balances must always resolve against a single token. Caller validates
the token is not a pool currency. Reverts {ZeroRewardToken} on the zero address and
{RewardTokenAlreadySet} if a token is already bound.


```solidity
function setRewardToken(Rewards storage self, VaultId id, IERC20 token) returns (Rewards storage self_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Rewards`| Capability storage.|
|`id`|`VaultId`|   The vault to configure.|
|`token`|`IERC20`|The reward ERC-20 to bind.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`self_`|`Rewards`|The capability storage, for chaining.|


