# IAggregatorHook
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/392f635329800dcebe64292f3cc7fa02fc61a68f/src/aggregator-hooks/interfaces/IAggregatorHook.sol)

**Title:**
IAggregatorHook

Interface for the AggregatorHook contract. An implemented aggregator hook should be able to use liquidity from external sources


## Functions
### quote

Quotes amount of unspecified side for a given amount of specified side

This function is meant to be called as a view function even though it is not one. This is because the swap
might be simulated but not finalized. Applies protocol fee on top of the raw quote from the underlying liquidity source


```solidity
function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    external
    payable
    returns (uint256 amountUnspecified);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`zeroToOne`|`bool`|Whether the swap is from token0 to token1 or from token1 to token0|
|`amountSpecified`|`int256`|The amount of tokens in or out (negative for exact-in, positive for exact-out)|
|`poolId`|`PoolId`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountUnspecified`|`uint256`|amount of unspecified side (always positive to adhere to practices by other quote functions)|


### pseudoTotalValueLocked

Returns the pseudo TVL: the amount of the UniswapV4 pool's tokens locked in the aggregated pool


```solidity
function pseudoTotalValueLocked(PoolId poolId) external returns (uint256 amount0, uint256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool ID of the UniswapV4 pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|The amount of token0 in the aggregated pool|
|`amount1`|`uint256`|The amount of token1 in the aggregated pool|


## Events
### AggregatorPoolRegistered

```solidity
event AggregatorPoolRegistered(PoolId indexed poolId);
```

### TokenJarUpdated

```solidity
event TokenJarUpdated(address indexed tokenJar);
```

### AggregatorHookSwap

```solidity
event AggregatorHookSwap(PoolId indexed poolId, address indexed sender, int256 amount0, int256 amount1);
```

## Errors
### UnspecifiedAmountExceeded

```solidity
error UnspecifiedAmountExceeded();
```

### PoolDoesNotExist

```solidity
error PoolDoesNotExist();
```

### LiquidityNotAllowed

```solidity
error LiquidityNotAllowed();
```

