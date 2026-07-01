# rewardTokenOf
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

The reward token bound to `id`, or `address(0)` if unconfigured.


```solidity
function rewardTokenOf(Rewards storage self, VaultId id) view returns (IERC20);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Rewards`|Capability storage.|
|`id`|`VaultId`|  The vault to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IERC20`|The bound reward ERC-20, or the zero address if unconfigured.|


