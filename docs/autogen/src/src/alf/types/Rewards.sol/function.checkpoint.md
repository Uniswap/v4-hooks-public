# checkpoint
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Settle accrual immediately before a share-balance change: advance the global index
against the OLD `totalSupply`, then credit `user` against their OLD `userShares`.

Pass `user == address(0)` to checkpoint only the global index (e.g. on funding).


```solidity
function checkpoint(
Rewards storage self,
VaultId id,
address user,
uint256 totalSupply,
uint256 userShares,
uint256 nowBlock
) returns (Rewards storage self_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Rewards`|       Capability storage.|
|`id`|`VaultId`|         The vault whose program to settle.|
|`user`|`address`|       The account to credit, or `address(0)` for index-only.|
|`totalSupply`|`uint256`|Total shares outstanding BEFORE the imminent mutation.|
|`userShares`|`uint256`| `user`'s share balance BEFORE the imminent mutation.|
|`nowBlock`|`uint256`|   The consumer's current block (from `_getBlockNumberish()`).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`self_`|`Rewards`|The capability storage, for chaining.|


