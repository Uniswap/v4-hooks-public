# IStableStableHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/924626d0c8f933c1c38d53555d77ded7e76f8009/src/interfaces/IStableStableHook.sol)

Interface for the StableStableHook


## Functions
### initializePool

Initialize a Uniswap v4 pool


```solidity
function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, FeeConfig calldata feeConfig)
    external
    returns (int24 tick);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to initialize|
|`sqrtPriceX96`|`uint160`|The initial starting price of the pool, expressed as a sqrtPriceX96|
|`feeConfig`|`FeeConfig`|The fee configuration for the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tick`|`int24`|The current tick of the pool|


### updateDecayFactor

Update the decay factor for a pool


```solidity
function updateDecayFactor(PoolKey calldata poolKey, uint256 decayFactor) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the decay factor for|
|`decayFactor`|`uint256`|The new decay factor|


### updateOptimalFeeSpread

Update the optimal fee spread for a pool


```solidity
function updateOptimalFeeSpread(PoolKey calldata poolKey, uint256 optimalFeeSpread) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the optimal fee spread for|
|`optimalFeeSpread`|`uint256`|The new optimal fee spread|


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


### clearHistoricalData

Clear the historical data for a pool


```solidity
function clearHistoricalData(PoolKey calldata poolKey) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to clear the historical data for|


## Errors
### MustUseDynamicFee
Error thrown when the pool trying to be initialized is not using a dynamic fee


```solidity
error MustUseDynamicFee(uint24 lpFee);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lpFee`|`uint24`|The LP fee that was used to try to initialize the pool|

### InvalidHookAddress
Error thrown when the hook address is not address(this)


```solidity
error InvalidHookAddress(address hookAddress);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`hookAddress`|`address`|The invalid hook address|

### InvalidInitializer
Error thrown when the caller of `initializePool` is not address(this)


```solidity
error InvalidInitializer(address caller);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|The invalid address attempting to initialize the pool|

### NotFeeController
Error thrown when the caller is not the fee controller


```solidity
error NotFeeController(address caller);
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

### OptimalFeeSpreadTooHigh
Error thrown when optimal fee spread is too high


```solidity
error OptimalFeeSpreadTooHigh(uint256 optimalFeeSpread);
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

