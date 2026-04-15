# StableSwapAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/0a9543d023e4a9afc81334cdd79c203f8feab340/src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md)

**Title:**
StableSwapAggregator

Uniswap V4 hook that aggregates liquidity from Curve StableSwap pools

Supports exact-input swaps only due to StableSwap pool limitations


## State Variables
### CURVE_NATIVE_ETH
Curve's address for native currency


```solidity
address private constant CURVE_NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
```


### pool
The Curve StableSwap pool


```solidity
ICurveStableSwap public immutable pool
```


### metaRegistry
The Curve MetaRegistry for checking meta pool status


```solidity
IMetaRegistry public immutable metaRegistry
```


### poolIdToTokenInfo
Maps Uniswap V4 pool IDs to their corresponding token indices in the Curve pool


```solidity
mapping(PoolId => PoolInfo) public poolIdToTokenInfo
```


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, ICurveStableSwap _pool, IMetaRegistry _metaRegistry)
    BaseAggregatorHook(_manager, "StableSwapAggregator v1.0");
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

### _currencyMatchesCoin

Check if a Curve pool coin matches a V4 currency (handles native: V4=address(0), Curve=0xEee)


```solidity
function _currencyMatchesCoin(Currency currency, address coin) internal pure returns (bool);
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


## Errors
### TokenNotInPool

```solidity
error TokenNotInPool(address token);
```

### TokensNotInPool

```solidity
error TokensNotInPool(address token0, address token1);
```

### ExactOutputNotSupported

```solidity
error ExactOutputNotSupported();
```

### PoolIsMetaPool

```solidity
error PoolIsMetaPool();
```

### PoolNotRegistered

```solidity
error PoolNotRegistered();
```

### ExchangeFailed

```solidity
error ExchangeFailed();
```

### InvalidPoolId

```solidity
error InvalidPoolId();
```

## Structs
### PoolInfo

```solidity
struct PoolInfo {
    int128 token0Index;
    int128 token1Index;
}
```

