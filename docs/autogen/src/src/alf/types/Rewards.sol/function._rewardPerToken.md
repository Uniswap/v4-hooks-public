# _rewardPerToken
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Current global reward-per-share index given the supply over the elapsed block window.


```solidity
function _rewardPerToken(Reward storage r, uint256 totalSupply, uint256 nowBlock) view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`r`|`Reward`|          The reward program to read.|
|`totalSupply`|`uint256`|The total shares the period accrues across.|
|`nowBlock`|`uint256`|   The consumer's current block.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The reward-per-share index, scaled by `REWARDS_PRECISION`.|


