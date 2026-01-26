# IConfigManager
[Git Source](https://github.com/Uniswap/v4-hooks/blob/52da5b5343d128438b4f25057129e9ba4367d580/src/stable/interfaces/IConfigManager.sol)

Interface for the ConfigManager


## Functions
### setConfigManager

Set the config manager


```solidity
function setConfigManager(address newConfigManager) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newConfigManager`|`address`|The address of the new config manager|


## Events
### ConfigManagerUpdated
Event emitted when the config manager is updated


```solidity
event ConfigManagerUpdated(address indexed configManager);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`configManager`|`address`|The new config manager|

## Errors
### NotConfigManager
Error thrown when the caller is not the config manager


```solidity
error NotConfigManager(address caller);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|The invalid address attempting to update the pool fee data|

