# recordClaims
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

Record newly-minted ERC-6909 claims for a bucket (after `pm.mint`).


```solidity
function recordClaims(Inventory storage self, bytes32 bucket, uint256 amount) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to credit.|
|`amount`|`uint256`|The claim amount minted (token's native decimals).|


