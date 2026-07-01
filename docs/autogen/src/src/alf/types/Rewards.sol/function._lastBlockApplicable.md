# _lastBlockApplicable
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

`min(nowBlock, periodFinishBlock)`; accrual stops at period end.


```solidity
function _lastBlockApplicable(Reward storage r, uint256 nowBlock) view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`r`|`Reward`|       The reward program to read.|
|`nowBlock`|`uint256`|The consumer's current block.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The latest block rewards still accrue for.|


