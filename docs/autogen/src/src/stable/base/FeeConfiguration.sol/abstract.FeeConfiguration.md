# FeeConfiguration
[Git Source](https://github.com/Uniswap/v4-hooks/blob/52da5b5343d128438b4f25057129e9ba4367d580/src/stable/base/FeeConfiguration.sol)

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


### clearHistoricalFeeData

Clear the historical data for a pool


```solidity
function clearHistoricalFeeData(PoolKey calldata poolKey) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to clear the historical data for|


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


### _getFeeConfig

Get the fee configuration for a pool


```solidity
function _getFeeConfig(PoolKey calldata poolKey) internal virtual returns (FeeConfig storage);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`FeeConfig`|The fee configuration for the pool|


### _getHistoricalFeeData

Get the historical fee data for a pool


```solidity
function _getHistoricalFeeData(PoolKey calldata poolKey) internal virtual returns (HistoricalFeeData storage);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`HistoricalFeeData`|The historical fee data for the pool|


