# claim
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Settle and pay out `user`'s accrued rewards.

The consumer passes the user's CURRENT share balance and CURRENT total supply (a claim
changes neither). Transfers the reward token to `user` and emits {RewardPaid}.


```solidity
function claim(
Rewards storage self,
VaultId id,
address user,
uint256 totalSupply,
uint256 userShares,
uint256 nowBlock
) returns (uint256 amount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Rewards`|       Capability storage.|
|`id`|`VaultId`|         The vault to claim from.|
|`user`|`address`|       The account to settle and pay.|
|`totalSupply`|`uint256`|The current total share supply.|
|`userShares`|`uint256`| `user`'s current share balance.|
|`nowBlock`|`uint256`|   The consumer's current block (from `_getBlockNumberish()`).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|The reward tokens transferred to `user` (token's native decimals).|


