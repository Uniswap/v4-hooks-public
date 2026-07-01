# RewardsDurationSet
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Emitted when a vault's reward period duration is set.


```solidity
event RewardsDurationSet(VaultId indexed vaultId, uint256 duration);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`| The vault whose duration was set.|
|`duration`|`uint256`|The new period length, in blocks.|

