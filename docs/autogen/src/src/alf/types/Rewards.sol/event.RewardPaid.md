# RewardPaid
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Emitted when a user claims accrued rewards.


```solidity
event RewardPaid(VaultId indexed vaultId, address indexed user, uint256 reward);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`|The vault claimed from.|
|`user`|`address`|   The account that claimed.|
|`reward`|`uint256`| The reward tokens transferred (token's native decimals).|

