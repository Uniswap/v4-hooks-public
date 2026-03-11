# StableSwapNGAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/17d7d5811380e775c83dd0663f30fb95c53d02b9/src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md)

**Title:**
StableSwapNGAggregator

Uniswap V4 hook that aggregates liquidity from Curve StableSwap NG pools

Supports both exact-input and exact-output swaps


## State Variables
### pool
The Curve StableSwap NG pool


```solidity
ICurveStableSwapNG public pool
```


### curveFactory
The Curve StableSwap NG factory for checking meta pool status


```solidity
ICurveStableSwapFactoryNG public curveFactory
```


### INACCURACY_BUFFER

```solidity
uint256 internal constant INACCURACY_BUFFER = 20
```


### INACCURACY_SCALE

```solidity
uint256 internal constant INACCURACY_SCALE = 1_000_000
```


### poolIdToTokenInfo
Maps Uniswap V4 pool IDs to their corresponding token indices in the Curve pool


```solidity
mapping(PoolId => PoolInfo) public poolIdToTokenInfo
```


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, ICurveStableSwapNG _pool, ICurveStableSwapFactoryNG _curveFactory)
    BaseAggregatorHook(_manager, "StableSwapNGAggregator v1.0");
```

### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees


```solidity
function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    internal
    view
    override
    returns (uint256 amountUnspecified);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`zeroToOne`|`bool`|Whether the swap is from token0 to token1|
|`amountSpecified`|`int256`|The amount specified (negative for exact-in, positive for exact-out)|
|`poolId`|`PoolId`|The pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountUnspecified`|`uint256`|The raw unspecified amount before protocol fee adjustment|


### pseudoTotalValueLocked


```solidity
function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1);
```

### _beforeInitialize


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4);
```

### _conductSwap

Abstract function for contracts to implement conducting the swap on the aggregated liquidity source

To settle the swap inside of the _conductSwap function, you must follow the 'sync, send,
settle' pattern and set hasSettled to true


```solidity
function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
    internal
    override
    returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`settleCurrency`|`Currency`|The currency to be settled on the V4 PoolManager (swapper's output currency)|
|`takeCurrency`|`Currency`|The currency to be taken from the V4 PoolManager (swapper's input currency)|
|`params`|`SwapParams`|The swap parameters|
|`poolId`|`PoolId`|The V4 Pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountSettle`|`uint256`|The amount of the currency being settled (swapper's output amount)|
|`amountTake`|`uint256`|The amount of the currency being taken (swapper's input amount)|
|`hasSettled`|`bool`|Whether the swap has been settled inside of the _conductSwap function|


### _handleSwap


```solidity
function _handleSwap(
    uint256 amountTake,
    int128 tokenInIndex,
    int128 tokenOutIndex,
    Currency settleCurrency,
    SwapParams calldata params
) internal returns (uint256 amountOut);
```

### _getBuffer


```solidity
function _getBuffer(uint256 amount) internal pure returns (uint256);
```

## Errors
### AmountOutExceeded

```solidity
error AmountOutExceeded();
```

### TokenNotInPool

```solidity
error TokenNotInPool(address token);
```

### TokensNotInPool

```solidity
error TokensNotInPool(address token0, address token1);
```

### PoolIsMetaPool

```solidity
error PoolIsMetaPool();
```

## Structs
### PoolInfo

```solidity
struct PoolInfo {
    int128 token0Index;
    int128 token1Index;
}
```

