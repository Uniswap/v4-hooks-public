# FeeConfiguration
[Git Source](https://github.com/Uniswap/v4-hooks/blob/d85a4c0f234196b046ed00df089e0e78e98074ef/src/stable/base/FeeConfiguration.sol)

**Inherits:**
[IFeeConfiguration](/src/stable/interfaces/IFeeConfiguration.sol/interface.IFeeConfiguration.md), BlockNumberish

**Title:**
FeeConfiguration

Abstract contract that implements the IFeeConfiguration interface


## State Variables
### MAX_OPTIMAL_FEE_E6
The maximum optimal fee in 1e6 precision: 1% (1e4 out of 1e6)


```solidity
uint256 public constant MAX_OPTIMAL_FEE_E6 = 1e4
```


### Q24
The scale used to preserve precision in decay factor math.


```solidity
uint256 internal constant Q24 = 2 ** 24
```


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


### _validateOptimalFeeE6

Validate the optimal fee


```solidity
function _validateOptimalFeeE6(uint256 _optimalFeeE6) internal pure;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_optimalFeeE6`|`uint256`|The optimal fee to validate|


### _validateReferenceSqrtPriceX96

Validate the reference sqrt price

The optimal range is defined in terms of PRICE (not sqrt price):
[referencePrice * (1 - maxOptimalFee), referencePrice / (1 - maxOptimalFee)]
Since price = sqrtPrice², the sqrt price bounds are:
[referenceSqrtPrice * sqrt(1 - maxOptimalFee), referenceSqrtPrice / sqrt(1 - maxOptimalFee)]
Note: MIN_SQRT_PRICE is valid (inclusive) but MAX_SQRT_PRICE is invalid (exclusive) in v4.


```solidity
function _validateReferenceSqrtPriceX96(uint256 _referenceSqrtPriceX96) internal pure;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_referenceSqrtPriceX96`|`uint256`|The reference sqrt price to validate|


### _resetFeeState

Internal helper to reset fee state


```solidity
function _resetFeeState(PoolId _poolId) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolId`|`PoolId`|The pool ID to reset fee state for|


