# ConfigManager
[Git Source](https://github.com/Uniswap/v4-hooks/blob/ec3cfb721a3661c7406618f534d9ae8887a128c1/src/ConfigManager.sol)

**Inherits:**
[IConfigManager](/src/interfaces/IConfigManager.sol/interface.IConfigManager.md)

**Title:**
ConfigManager

Abstract contract that implements the IConfigManager interface


## State Variables
### configManager
The address of the config manager

The config manager is the address that can update the fee configuration for a pool


```solidity
address public configManager
```


## Functions
### constructor


```solidity
constructor(address _configManager) ;
```

### onlyConfigManager

Modifier to only allow calls from the config manager

This modifier is used to prevent unauthorized updates to the fee configuration per pool


```solidity
modifier onlyConfigManager() ;
```

### setConfigManager

Set the config manager


```solidity
function setConfigManager(address newConfigManager) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newConfigManager`|`address`|The address of the new config manager|


