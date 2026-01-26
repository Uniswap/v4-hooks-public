# FeeConfiguration
[Git Source](https://github.com/Uniswap/v4-hooks/blob/00674b730d2e683e2e0113e347bb7dc3b38fc03b/src/stable/base/FeeConfiguration.sol)

**Inherits:**
[ConfigManager](/src/stable/base/ConfigManager.sol/abstract.ConfigManager.md), [IFeeConfiguration](/src/stable/interfaces/IFeeConfiguration.sol/interface.IFeeConfiguration.md)

**Title:**
FeeConfiguration

Abstract contract that implements the IFeeConfiguration interface


## State Variables
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
constructor(address _configManager) ConfigManager(_configManager);
```

### updateDecayFactor

Update the decay factor for a pool

Should be called in a multicall with clearHistoricalFeeData()


```solidity
function updateDecayFactor(PoolKey calldata poolKey, uint256 decayFactor) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the decay factor for|
|`decayFactor`|`uint256`|The new decay factor|


### updateOptimalFeeRate

Update the optimal fee spread for a pool

Should be called in a multicall with clearHistoricalFeeData()


```solidity
function updateOptimalFeeRate(PoolKey calldata poolKey, uint24 optimalFeeRate) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the optimal fee rate for|
|`optimalFeeRate`|`uint24`|The new optimal fee rate|


### updateReferenceSqrtPrice

Update the reference sqrt price for a pool

Should be called in a multicall with clearHistoricalFeeData()


```solidity
function updateReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPriceX96)
    external
    onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the reference sqrt price for|
|`referenceSqrtPriceX96`|`uint160`||


### resetHistoricalFeeData

Reset the historical data for a pool


```solidity
function resetHistoricalFeeData(PoolKey calldata poolKey) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to reset the historical data for|


### _validateFeeConfig

Internal helper to initialize fee configuration and historical data


```solidity
function _validateFeeConfig(PoolId poolId, FeeConfig calldata feeConfiguration) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool ID to initialize|
|`feeConfiguration`|`FeeConfig`|The fee configuration to set|


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
function _resetHistoricalFeeData(PoolId poolId) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool ID to reset historical data for|


