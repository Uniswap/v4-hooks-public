# StableSwapAggregatorFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/cefd9a2a30a0453cd2f2edc430198596f38b6004/src/aggregator-hooks/implementations/StableSwap/StableSwapAggregatorFactory.sol)

**Title:**
StableSwapAggregatorFactory

Factory for creating StableSwapAggregator hooks via CREATE2 and initializing Uniswap V4 pools

Deploys deterministic hook addresses and initializes pools for all token pairs in the Curve pool


## State Variables
### poolManager
The Uniswap V4 PoolManager contract


```solidity
IPoolManager public immutable poolManager
```


### metaRegistry
The Curve MetaRegistry for checking meta pool status


```solidity
IMetaRegistry public immutable metaRegistry
```


### deployments
All deployments, indexed by creation order

The auto-generated getter omits the poolKeys array; use getDeployment for the full record


```solidity
Deployment[] public deployments
```


### hookForPool
The hook deployed for a given Curve pool (address(0) if none)


```solidity
mapping(address curvePool => address hook) public hookForPool
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, IMetaRegistry _metaRegistry) ;
```

### createPool

Creates a new StableSwapAggregator hook and initializes pools for all token pairs

Note: The token count must match the Curve pool's coin count,
so every token pair is initialized in this single call


```solidity
function createPool(
    bytes32 salt,
    ICurveStableSwap curvePool,
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
|`curvePool`|`ICurveStableSwap`|The Curve StableSwap pool to aggregate|
|`tokens`|`Currency[]`|Array of currencies in the pool (must contain exactly the pool's coins)|
|`fee`|`uint24`|The pool fee|
|`tickSpacing`|`int24`|The pool tick spacing|
|`sqrtPriceX96`|`uint160`|The initial sqrt price for each pool|

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

Returns the full deployment record (including all pool keys) for a deployment index


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
function computeAddress(bytes32 salt, ICurveStableSwap curvePool) external view returns (address computedAddress);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`salt`|`bytes32`|The CREATE2 salt|
|`curvePool`|`ICurveStableSwap`|The Curve StableSwap pool|

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

### DuplicateTokens

```solidity
error DuplicateTokens(Currency token);
```

### DuplicatePool

```solidity
error DuplicatePool(address curvePool, address existingHook);
```

### TokenCountMismatch

```solidity
error TokenCountMismatch(uint256 provided);
```

## Structs
### Deployment
Full record of a hook deployment


```solidity
struct Deployment {
    address hook;
    address curvePool;
    PoolKey[] poolKeys;
}
```

