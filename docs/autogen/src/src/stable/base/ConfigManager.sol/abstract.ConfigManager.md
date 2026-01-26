# ConfigManager
[Git Source](https://github.com/Uniswap/v4-hooks/blob/52da5b5343d128438b4f25057129e9ba4367d580/src/stable/base/ConfigManager.sol)

**Inherits:**
[IConfigManager](/src/stable/interfaces/IConfigManager.sol/interface.IConfigManager.md)

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


