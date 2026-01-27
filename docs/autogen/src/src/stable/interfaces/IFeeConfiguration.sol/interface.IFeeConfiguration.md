# IFeeConfiguration
[Git Source](https://github.com/Uniswap/v4-hooks/blob/c30efe567d08994ae07b3496ff1329cfd23f4065/src/stable/interfaces/IFeeConfiguration.sol)

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


### updateDecayFactor

Update the decay factor for a pool


```solidity
function updateDecayFactor(PoolId poolId, uint256 decayFactor) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool to update the decay factor for|
|`decayFactor`|`uint256`|The new decay factor|


### updateOptimalFeeRate

Update the optimal fee spread for a pool


```solidity
function updateOptimalFeeRate(PoolId poolId, uint24 optimalFeeRate) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool to update the optimal fee rate for|
|`optimalFeeRate`|`uint24`|The new optimal fee rate|


### updateReferenceSqrtPriceX96

Update the reference sqrt price for a pool


```solidity
function updateReferenceSqrtPriceX96(PoolId poolId, uint160 referenceSqrtPriceX96) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool to update the reference sqrt price for|
|`referenceSqrtPriceX96`|`uint160`|The new reference sqrt price|


### resetHistoricalFeeData

Reset the historical data for a pool


```solidity
function resetHistoricalFeeData(PoolId poolId) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool to reset the historical data for|


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

### DecayFactorUpdated
Event emitted when the decay factor is updated


```solidity
event DecayFactorUpdated(PoolId indexed poolId, uint256 decayFactor);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool|
|`decayFactor`|`uint256`|The new decay factor|

### OptimalFeeRateUpdated
Event emitted when the optimal fee rate is updated


```solidity
event OptimalFeeRateUpdated(PoolId indexed poolId, uint256 optimalFeeRate);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool|
|`optimalFeeRate`|`uint256`|The new optimal fee rate|

### ReferenceSqrtPriceX96Updated
Event emitted when the reference sqrt price is updated


```solidity
event ReferenceSqrtPriceX96Updated(PoolId indexed poolId, uint160 referenceSqrtPriceX96);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool|
|`referenceSqrtPriceX96`|`uint160`|The new reference sqrt price|

### HistoricalFeeDataReset
Event emitted when the historical fee data is reset


```solidity
event HistoricalFeeDataReset(PoolId indexed poolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool|

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

### InvalidDecayFactor
Error thrown when decay factor is invalid


```solidity
error InvalidDecayFactor(uint256 decayFactor);
```

### OptimalFeeRateTooHigh
Error thrown when optimal fee rate is too high


```solidity
error OptimalFeeRateTooHigh(uint256 optimalFeeRate);
```

### InvalidReferenceSqrtPrice
Error thrown when reference sqrt price is invalid


```solidity
error InvalidReferenceSqrtPrice(uint160 invalidSqrtPrice);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`invalidSqrtPrice`|`uint160`|The invalid reference sqrt price|

