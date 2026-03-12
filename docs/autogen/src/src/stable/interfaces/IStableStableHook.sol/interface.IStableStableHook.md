# IStableStableHook
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/17d7d5811380e775c83dd0663f30fb95c53d02b9/src/stable/interfaces/IStableStableHook.sol)

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
|`feeConfig`|`FeeConfig`|The fee config for the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tick`|`int24`|The current tick of the pool|


## Events
### PoolInitialized
Event emitted when a pool is initialized


```solidity
event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, FeeConfig feeConfig);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool|
|`sqrtPriceX96`|`uint160`|The initial starting price of the pool, expressed as a sqrtPriceX96|
|`feeConfig`|`FeeConfig`|The fee config for the pool|

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

