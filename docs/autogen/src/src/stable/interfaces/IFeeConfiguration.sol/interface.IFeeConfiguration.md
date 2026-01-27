# IFeeConfiguration
[Git Source](https://github.com/Uniswap/v4-hooks/blob/fd6c246f56c71ed20e67ce06ce552b22eb9e0620/src/stable/interfaces/IFeeConfiguration.sol)

Interface for the FeeConfiguration


## Functions
### setConfigManager

Set the config manager


```solidity
function setConfigManager(address configManager) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`configManager`|`address`|The address of the new config manager|


### updateFeeConfig

Update the fee config for a pool


```solidity
function updateFeeConfig(PoolId poolId, FeeConfig calldata feeConfig) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool|
|`feeConfig`|`FeeConfig`|The new fee config|


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

### FeeConfigUpdated
Event emitted when the fee config is updated


```solidity
event FeeConfigUpdated(PoolId indexed poolId, FeeConfig feeConfig);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool|
|`feeConfig`|`FeeConfig`|The new fee config|

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

### InvalidKAndLogK
Error thrown when k and logK are invalid


```solidity
error InvalidKAndLogK(uint256 k, uint256 logK);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`k`|`uint256`|The invalid k value|
|`logK`|`uint256`|The invalid logK value|

### InvalidOptimalFeeRate
Error thrown when optimal fee rate is invalid


```solidity
error InvalidOptimalFeeRate(uint256 optimalFeeRate);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`optimalFeeRate`|`uint256`|The invalid optimal fee rate|

### InvalidReferenceSqrtPrice
Error thrown when reference sqrt price is invalid


```solidity
error InvalidReferenceSqrtPrice(uint160 invalidSqrtPrice);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`invalidSqrtPrice`|`uint160`|The invalid reference sqrt price|

