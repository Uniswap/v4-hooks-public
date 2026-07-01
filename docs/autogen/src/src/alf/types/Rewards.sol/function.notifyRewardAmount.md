# notifyRewardAmount
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Fund a new reward period (or top up the active one).

The consumer MUST have already transferred `reward` of the reward token to its own
custody. Settles the global index first, recomputes `rewardRate` (folding in any leftover
from an active period), and bounds the rate against `onHandBalance` so accrual can never
outrun funding. The consumer passes its post-transfer reward-token balance (free functions
have no `address(this)` of their own). Reverts {RewardTokenNotSet},
{RewardsDurationNotSet}, or {RewardRateTooHigh}.


```solidity
function notifyRewardAmount(
Rewards storage self,
VaultId id,
uint256 reward,
uint256 totalSupply,
uint256 onHandBalance,
uint256 nowBlock
) returns (Rewards storage self_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Rewards`|         Capability storage.|
|`id`|`VaultId`|           The vault to fund.|
|`reward`|`uint256`|       Reward tokens added to the period (token's native decimals).|
|`totalSupply`|`uint256`|  Current total shares outstanding (for the index settle).|
|`onHandBalance`|`uint256`|The consumer's current reward-token balance (post-transfer), bounding the rate.|
|`nowBlock`|`uint256`|     The consumer's current block (from `_getBlockNumberish()`).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`self_`|`Rewards`|The capability storage, for chaining.|


