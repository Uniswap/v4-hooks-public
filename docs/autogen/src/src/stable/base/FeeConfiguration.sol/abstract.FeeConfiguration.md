# FeeConfiguration
[Git Source](https://github.com/Uniswap/v4-hooks/blob/c30efe567d08994ae07b3496ff1329cfd23f4065/src/stable/base/FeeConfiguration.sol)

**Inherits:**
[IFeeConfiguration](/src/stable/interfaces/IFeeConfiguration.sol/interface.IFeeConfiguration.md)

**Title:**
FeeConfiguration

Abstract contract that implements the IFeeConfiguration interface


## State Variables
### configManager
The address of the config manager

The config manager is the address that can update the fee configuration for a pool


```solidity
address public configManager
```


### feeConfig
The fee configuration for each pool


```solidity
mapping(PoolId => FeeConfig) public feeConfig
```


### historicalFeeData
The historical data for each pool


```solidity
mapping(PoolId => HistoricalFeeData) public historicalFeeData
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
function setConfigManager(address configManager_) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`configManager_`|`address`||


### updateDecayFactor

Update the decay factor for a pool

Should be called in a multicall with resetHistoricalFeeData()


```solidity
function updateDecayFactor(PoolId poolId, uint256 decayFactor) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool to update the decay factor for|
|`decayFactor`|`uint256`|The new decay factor|


### updateOptimalFeeRate

Update the optimal fee spread for a pool

Should be called in a multicall with resetHistoricalFeeData()


```solidity
function updateOptimalFeeRate(PoolId poolId, uint24 optimalFeeRate) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool to update the optimal fee rate for|
|`optimalFeeRate`|`uint24`|The new optimal fee rate|


### updateReferenceSqrtPriceX96

Update the reference sqrt price for a pool

Should be called in a multicall with resetHistoricalFeeData()


```solidity
function updateReferenceSqrtPriceX96(PoolId poolId, uint160 referenceSqrtPriceX96) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool to update the reference sqrt price for|
|`referenceSqrtPriceX96`|`uint160`|The new reference sqrt price|


### resetHistoricalFeeData

Reset the historical data for a pool


```solidity
function resetHistoricalFeeData(PoolId poolId) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The ID of the pool to reset the historical data for|


### _validateFeeConfig

Internal helper to initialize fee configuration and historical data


```solidity
function _validateFeeConfig(PoolId _poolId, FeeConfig calldata _feeConfiguration) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolId`|`PoolId`|The pool ID to initialize|
|`_feeConfiguration`|`FeeConfig`|The fee configuration to set|


### _validateDecayFactor

Validate the decay factor


```solidity
function _validateDecayFactor(uint256 _decayFactor) internal pure;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_decayFactor`|`uint256`|The decay factor to validate|


### _validateOptimalFeeRate

Validate the optimal fee rate


```solidity
function _validateOptimalFeeRate(uint256 _optimalFeeRate) internal pure;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_optimalFeeRate`|`uint256`|The optimal fee rate to validate|


### _validateReferenceSqrtPrice

Validate the reference sqrt price


```solidity
function _validateReferenceSqrtPrice(uint160 _referenceSqrtPriceX96) internal pure;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_referenceSqrtPriceX96`|`uint160`|The reference sqrt price to validate|


### _resetHistoricalFeeData

Internal helper to reset historical fee data


```solidity
function _resetHistoricalFeeData(PoolId _poolId) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolId`|`PoolId`|The pool ID to reset historical data for|


