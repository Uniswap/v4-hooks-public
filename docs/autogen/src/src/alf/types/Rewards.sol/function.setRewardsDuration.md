# setRewardsDuration
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Set the reward period length for `id`.

Only permitted between periods, since changing it mid-period would retroactively rescale
the active rate. Reverts {RewardsDurationNotSet} on zero and {RewardPeriodActive} while a
period is live.


```solidity
function setRewardsDuration(Rewards storage self, VaultId id, uint256 duration, uint256 nowBlock)
returns (Rewards storage self_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Rewards`|    Capability storage.|
|`id`|`VaultId`|      The vault to configure.|
|`duration`|`uint256`|The period length, in blocks.|
|`nowBlock`|`uint256`|The consumer's current block (from `_getBlockNumberish()`).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`self_`|`Rewards`|The capability storage, for chaining.|


