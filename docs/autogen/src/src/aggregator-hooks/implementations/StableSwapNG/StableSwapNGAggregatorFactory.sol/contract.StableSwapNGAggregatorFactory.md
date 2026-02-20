# StableSwapNGAggregatorFactory
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/37a7cb81b7d428c0f0c3a3b22f8af4d012f72874/src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregatorFactory.sol)

**Title:**
StableSwapNGAggregatorFactory

Factory for creating StableSwapNGAggregator hooks via CREATE2 and initializing Uniswap V4 pools

Deploys deterministic hook addresses and initializes pools for all token pairs in the Curve pool


## State Variables
### poolManager
The Uniswap V4 PoolManager contract


```solidity
IPoolManager public immutable poolManager
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager) ;
```

### createPool

Creates a new StableSwapNGAggregator hook and initializes pools for all token pairs


```solidity
function createPool(
    bytes32 salt,
    ICurveStableSwapNG curvePool,
    Currency[] calldata tokens,
    uint24 fee,
    int24 tickSpacing,
    uint160 sqrtPriceX96
) external returns (address hook);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`salt`|`bytes32`|The CREATE2 salt (pre-mined to produce valid hook address)|
|`curvePool`|`ICurveStableSwapNG`|The Curve StableSwap NG pool to aggregate|
|`tokens`|`Currency[]`|Array of currencies in the pool (must have at least 2 tokens)|
|`fee`|`uint24`|The pool fee|
|`tickSpacing`|`int24`|The pool tick spacing|
|`sqrtPriceX96`|`uint160`|The initial sqrt price for each pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`hook`|`address`|The deployed hook address|


### computeAddress

Computes the CREATE2 address for a hook without deploying


```solidity
function computeAddress(bytes32 salt, ICurveStableSwapNG curvePool)
    external
    view
    returns (address computedAddress);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`salt`|`bytes32`|The CREATE2 salt|
|`curvePool`|`ICurveStableSwapNG`|The Curve StableSwap NG pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`computedAddress`|`address`|The predicted hook address|


## Events
### HookDeployed

```solidity
event HookDeployed(address indexed hook, address indexed curvePool, PoolKey poolKey);
```

## Errors
### InsufficientTokens

```solidity
error InsufficientTokens();
```

