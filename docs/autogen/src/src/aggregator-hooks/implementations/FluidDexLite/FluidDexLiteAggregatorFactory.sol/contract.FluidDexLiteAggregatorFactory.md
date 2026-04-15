# FluidDexLiteAggregatorFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/9518e85469f947d05f4f704e2ffa3a584bf5f201/src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregatorFactory.sol)

Factory for creating FluidDexLiteAggregator hooks via CREATE2 and initializing Uniswap V4 pools

Deploys deterministic hook addresses that meet Uniswap V4's hook address requirements


## State Variables
### poolManager
The Uniswap V4 PoolManager contract


```solidity
IPoolManager public immutable poolManager
```


### fluidDexLite
The Fluid DEX Lite contract


```solidity
IFluidDexLite public immutable fluidDexLite
```


### fluidDexLiteResolver
The Fluid DEX Lite resolver for pool state queries


```solidity
IFluidDexLiteResolver public immutable fluidDexLiteResolver
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, IFluidDexLite _fluidDexLite, IFluidDexLiteResolver _fluidDexLiteResolver) ;
```

### createPool

Creates a new FluidDexLiteAggregator hook and initializes the pool


```solidity
function createPool(
    bytes32 salt,
    bytes32 dexSalt,
    Currency currency0,
    Currency currency1,
    uint24 fee,
    int24 tickSpacing,
    uint160 sqrtPriceX96
) external returns (address hook);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`salt`|`bytes32`|The CREATE2 salt (pre-mined to produce valid hook address)|
|`dexSalt`|`bytes32`|The salt for the Fluid DEX Lite pool's DexKey|
|`currency0`|`Currency`|The first currency of the pool (must be < currency1)|
|`currency1`|`Currency`|The second currency of the pool|
|`fee`|`uint24`|The pool fee|
|`tickSpacing`|`int24`|The pool tick spacing|
|`sqrtPriceX96`|`uint160`|The initial sqrt price for the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`hook`|`address`|The deployed hook address|


### computeAddress

Computes the CREATE2 address for a hook without deploying


```solidity
function computeAddress(bytes32 salt, bytes32 dexSalt) external view returns (address computedAddress);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`salt`|`bytes32`|The CREATE2 salt|
|`dexSalt`|`bytes32`|The salt for the Fluid DEX Lite pool's DexKey|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`computedAddress`|`address`|The predicted hook address|


## Events
### HookDeployed

```solidity
event HookDeployed(address indexed hook, bytes32 indexed dexSalt, PoolKey poolKey);
```

