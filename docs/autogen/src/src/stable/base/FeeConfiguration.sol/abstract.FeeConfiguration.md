# FeeConfiguration
[Git Source](https://github.com/Uniswap/v4-hooks/blob/7dcd775c7e3ae809200c0a0161e8e569c246c698/src/stable/base/FeeConfiguration.sol)

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
The fee config for each pool


```solidity
mapping(PoolId => FeeConfig) public feeConfig
```


### feeState
The fee state for each pool


```solidity
mapping(PoolId => FeeState) public feeState
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


### updateFeeConfig

Update the fee config for a pool


```solidity
function updateFeeConfig(PoolId poolId_, FeeConfig calldata feeConfig_) external onlyConfigManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId_`|`PoolId`||
|`feeConfig_`|`FeeConfig`||


### _updateFeeConfig

Internal helper to initialize fee config and fee state


```solidity
function _updateFeeConfig(PoolId _poolId, FeeConfig calldata _feeConfig) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolId`|`PoolId`|The pool ID to initialize|
|`_feeConfig`|`FeeConfig`|The fee config to set|


### _validateKAndLogK

Validate the decay factor


```solidity
function _validateKAndLogK(uint256 _k, uint256 _logK) internal pure;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_k`|`uint256`|The k value to validate|
|`_logK`|`uint256`|The logK value to validate|


### _validateOptimalFeeRateE6

Validate the optimal fee rate


```solidity
function _validateOptimalFeeRateE6(uint24 _optimalFeeRateE6) internal pure;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_optimalFeeRateE6`|`uint24`|The optimal fee rate to validate|


### _validateReferenceSqrtPriceX96

Validate the reference sqrt price


```solidity
function _validateReferenceSqrtPriceX96(uint160 _referenceSqrtPriceX96) internal pure;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_referenceSqrtPriceX96`|`uint160`|The reference sqrt price to validate|


### _resetFeeState

Internal helper to reset fee state


```solidity
function _resetFeeState(PoolId _poolId) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolId`|`PoolId`|The pool ID to reset fee state for|


