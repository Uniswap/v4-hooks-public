# RewardTokenSet
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Emitted when a vault's reward token is bound.


```solidity
event RewardTokenSet(VaultId indexed vaultId, address token);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`|The vault whose reward token was set.|
|`token`|`address`|  The reward ERC-20 token address.|

