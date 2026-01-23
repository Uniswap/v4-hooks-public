# FeeConfiguration
[Git Source](https://github.com/Uniswap/v4-hooks/blob/cc39bad2f9286aefd0824c4bc93d241fe8657275/src/FeeConfiguration.sol)

**Inherits:**
[FeeController](/src/FeeController.sol/abstract.FeeController.md), [IFeeConfiguration](/src/interfaces/IFeeConfiguration.sol/interface.IFeeConfiguration.md)

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
constructor(address _feeController) FeeController(_feeController);
```

### updateDecayFactor

Update the decay factor for a pool

Should be called in a multicall with clearHistoricalFeeData()


```solidity
function updateDecayFactor(PoolKey calldata poolKey, uint256 decayFactor) external onlyFeeController;
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
function updateOptimalFeeRate(PoolKey calldata poolKey, uint24 optimalFeeRate) external onlyFeeController;
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
    onlyFeeController;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the reference sqrt price for|
|`referenceSqrtPriceX96`|`uint160`||


### clearHistoricalFeeData

Clear the historical data for a pool


```solidity
function clearHistoricalFeeData(PoolKey calldata poolKey) external onlyFeeController;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to clear the historical data for|


### _validateDecayFactor


```solidity
function _validateDecayFactor(uint256 _decayFactor) internal pure;
```

### _validateOptimalFeeRate


```solidity
function _validateOptimalFeeRate(uint256 _optimalFeeRate) internal pure;
```

### _validateReferenceSqrtPrice


```solidity
function _validateReferenceSqrtPrice(uint160 _referenceSqrtPriceX96) internal pure;
```

### _getFeeConfig


```solidity
function _getFeeConfig(PoolKey calldata poolKey) internal virtual returns (FeeConfig storage);
```

### _getHistoricalFeeData


```solidity
function _getHistoricalFeeData(PoolKey calldata poolKey) internal virtual returns (HistoricalFeeData storage);
```

