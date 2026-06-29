# UniswapXAggregatorFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/56fe7f485c8d67008228c24d14664f55752c8c93/src/aggregator-hooks/implementations/UniswapX/UniswapXAggregatorFactory.sol)

**Title:**
UniswapXAggregatorFactory

Factory for creating UniswapXAggregator hooks via CREATE2 and initializing a Uniswap V4 pool

Deploys deterministic hook addresses (salt pre-mined to encode hook permission flags) and initializes
the V4 pool whose currencies are the order's input/output token pair.


## State Variables
### poolManager
The Uniswap V4 PoolManager contract


```solidity
IPoolManager public immutable poolManager
```


### reactor
The UniswapX reactor the deployed hooks fill orders against


```solidity
IReactor public immutable reactor
```


### weth
The canonical wrapped-native token


```solidity
address public immutable weth
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, IReactor _reactor, address _weth) ;
```

### createPool

Creates a new UniswapXAggregator hook and initializes a V4 pool for the given currency pair


```solidity
function createPool(
    bytes32 salt,
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
|`salt`|`bytes32`|The CREATE2 salt (pre-mined to produce a valid hook address)|
|`currency0`|`Currency`|The lower-sorted pool currency|
|`currency1`|`Currency`|The higher-sorted pool currency|
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
function computeAddress(bytes32 salt) external view returns (address computedAddress);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`salt`|`bytes32`|The CREATE2 salt|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`computedAddress`|`address`|The predicted hook address|


## Events
### HookDeployed

```solidity
event HookDeployed(address indexed hook, address indexed reactor, PoolKey poolKey);
```

