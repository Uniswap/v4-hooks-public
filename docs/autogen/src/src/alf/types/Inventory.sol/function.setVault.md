# setVault
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

Bind `vault` to `bucket`. Caller validates the vault matches the currency.


```solidity
function setVault(Inventory storage self, bytes32 bucket, IERC4626 vault) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to configure.|
|`vault`|`IERC4626`| The ERC-4626 vault to bind (`address(0)` to hold the currency as raw ERC-20).|


