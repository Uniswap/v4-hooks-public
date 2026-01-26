# IFeeConfiguration
[Git Source](https://github.com/Uniswap/v4-hooks/blob/56d233d0b250177bdf941e4e02adb122dab011ae/src/stable/interfaces/IFeeConfiguration.sol)

Interface for the FeeConfiguration


## Functions
### updateDecayFactor

Update the decay factor for a pool


```solidity
function updateDecayFactor(PoolKey calldata poolKey, uint256 k, uint256 logK) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the decay factor for|
|`k`|`uint256`|The new k|
|`logK`|`uint256`|The new logK|


### updateOptimalFeeRate

Update the optimal fee spread for a pool


```solidity
function updateOptimalFeeRate(PoolKey calldata poolKey, uint24 optimalFeeRate) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the optimal fee rate for|
|`optimalFeeRate`|`uint24`|The new optimal fee rate|


### updateReferenceSqrtPrice

Update the reference sqrt price for a pool


```solidity
function updateReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPrice) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the reference sqrt price for|
|`referenceSqrtPrice`|`uint160`|The new reference sqrt price|


### resetHistoricalFeeData

Reset the historical data for a pool


```solidity
function resetHistoricalFeeData(PoolKey calldata poolKey) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to reset the historical data for|


## Events
### DecayFactorUpdated
Event emitted when the decay factor is updated


```solidity
event DecayFactorUpdated(PoolKey indexed poolKey, uint256 k, uint256 logK);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool|
|`k`|`uint256`|The new k|
|`logK`|`uint256`|The new logK|

### OptimalFeeRateUpdated
Event emitted when the optimal fee rate is updated


```solidity
event OptimalFeeRateUpdated(PoolKey indexed poolKey, uint256 optimalFeeRate);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool|
|`optimalFeeRate`|`uint256`|The new optimal fee rate|

### ReferenceSqrtPriceUpdated
Event emitted when the reference sqrt price is updated


```solidity
event ReferenceSqrtPriceUpdated(PoolKey indexed poolKey, uint160 referenceSqrtPrice);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool|
|`referenceSqrtPrice`|`uint160`|The new reference sqrt price|

### HistoricalFeeDataReset
Event emitted when the historical fee data is reset


```solidity
event HistoricalFeeDataReset(PoolKey indexed poolKey);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool|

## Errors
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

