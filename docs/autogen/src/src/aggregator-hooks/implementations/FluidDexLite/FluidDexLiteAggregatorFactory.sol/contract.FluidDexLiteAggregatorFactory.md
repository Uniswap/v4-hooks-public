# FluidDexLiteAggregatorFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/c8009b0f70f3ba0a73cedd796c1cbe2ddce0ddbb/src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregatorFactory.sol)

**Title:**
FluidDexLiteAggregatorFactory

Factory for creating FluidDexLiteAggregator hooks via CREATE2 and initializing Uniswap V4 pools

Deploys deterministic hook addresses that meet Uniswap V4's hook address requirements


## Constants
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


## State Variables
### deployments
All deployments, indexed by creation order


```solidity
Deployment[] public deployments
```


### hookForDexKeyHash
The hook deployed for a given Fluid DEX Lite pool, keyed by
keccak256(abi.encode(currency0, currency1, dexSalt)) (address(0) if none)


```solidity
mapping(bytes32 dexKeyHash => address hook) public hookForDexKeyHash
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


### deploymentCount

Total number of hooks deployed by this factory


```solidity
function deploymentCount() external view returns (uint256);
```

### getDeployment

Returns the full deployment record for a deployment index


```solidity
function getDeployment(uint256 index) external view returns (Deployment memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`index`|`uint256`|The deployment index (in creation order)|


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

## Errors
### DuplicatePool

```solidity
error DuplicatePool(bytes32 dexSalt, Currency currency0, Currency currency1, address existingHook);
```

## Structs
### Deployment
Full record of a hook deployment


```solidity
struct Deployment {
    address hook;
    bytes32 dexSalt;
    PoolKey poolKey;
}
```

