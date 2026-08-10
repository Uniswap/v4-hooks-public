# FluidDexT1AggregatorFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/b79803a2ede9257f7b93a8c746a6d78104abcfb3/src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1AggregatorFactory.sol)

**Title:**
FluidDexT1AggregatorFactory

Factory for creating FluidDexT1Aggregator hooks via CREATE2 and initializing Uniswap V4 pools

Deploys deterministic hook addresses that meet Uniswap V4's hook address requirements


## Constants
### poolManager
The Uniswap V4 PoolManager contract


```solidity
IPoolManager public immutable poolManager
```


### fluidDexReservesResolver
The Fluid DEX reserves resolver for pool state queries


```solidity
IFluidDexReservesResolver public immutable fluidDexReservesResolver
```


### fluidDexResolver
The Fluid DEX resolver for swap queries


```solidity
IFluidDexResolver public immutable fluidDexResolver
```


### fluidLiquidity
The Fluid Liquidity Layer contract address


```solidity
address public immutable fluidLiquidity
```


## State Variables
### deployments
All deployments, indexed by creation order


```solidity
Deployment[] public deployments
```


### hookForPool
The hook deployed for a given Fluid DEX T1 pool (address(0) if none)


```solidity
mapping(address fluidPool => address hook) public hookForPool
```


## Functions
### constructor


```solidity
constructor(
    IPoolManager _poolManager,
    IFluidDexReservesResolver _fluidDexReservesResolver,
    IFluidDexResolver _fluidDexResolver,
    address _fluidLiquidity
) ;
```

### createPool

Creates a new FluidDexT1Aggregator hook and initializes the pool


```solidity
function createPool(
    bytes32 salt,
    IFluidDexT1 fluidPool,
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
|`fluidPool`|`IFluidDexT1`|The Fluid DEX T1 pool to aggregate|
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
function computeAddress(bytes32 salt, IFluidDexT1 fluidPool) external view returns (address computedAddress);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`salt`|`bytes32`|The CREATE2 salt|
|`fluidPool`|`IFluidDexT1`|The Fluid DEX T1 pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`computedAddress`|`address`|The predicted hook address|


## Events
### HookDeployed

```solidity
event HookDeployed(address indexed hook, address indexed fluidPool, PoolKey poolKey);
```

## Errors
### HookAddressMismatch

```solidity
error HookAddressMismatch(address expected, address actual);
```

### DuplicatePool

```solidity
error DuplicatePool(address fluidPool, address existingHook);
```

## Structs
### Deployment
Full record of a hook deployment


```solidity
struct Deployment {
    address hook;
    address fluidPool;
    PoolKey poolKey;
}
```

