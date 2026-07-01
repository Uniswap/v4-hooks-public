# VaultBound
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

Emitted when a vault is bound to a bucket via {setVault} (`address(0)` unbinds to raw ERC-20).


```solidity
event VaultBound(bytes32 indexed bucket, IERC4626 vault);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`bucket`|`bytes32`|The accounting partition reconfigured.|
|`vault`|`IERC4626`| The ERC-4626 vault now bound to the bucket.|

