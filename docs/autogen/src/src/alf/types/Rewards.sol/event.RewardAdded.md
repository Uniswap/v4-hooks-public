# RewardAdded
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Emitted when a reward period is funded (or topped up).


```solidity
event RewardAdded(VaultId indexed vaultId, uint256 reward, uint256 periodFinishBlock);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`|          The vault that was funded.|
|`reward`|`uint256`|           The reward tokens added to the period (token's native decimals).|
|`periodFinishBlock`|`uint256`|The block the (re)started period now ends.|

