# IALFHook
[Git Source](https://0.1/http://local_proxy@127.0.41729/git/uniswap/v4-hooks-public/blob/3a3caa3989f59df19eb774129a7c4a5daebc08e7/src/aggregator-hooks/interfaces/IALFHook.sol)

**Inherits:**
IERC165

Router-facing ALF interface for custom-accounting hooks.

Vendored from URC-4 (Active Liquidity Framework Hook Interface) reference implementation.


## Functions
### getIndicativeQuote

Get a non-binding indicative quote.

Returns 0 when the hook cannot price the swap under normal conditions.
Reverts with MissingHookData or MalformedHookData for missing or
undecodable hookData.


```solidity
function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
    external
    returns (uint256 quoteAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool key.|
|`zeroForOne`|`bool`|Swap direction.|
|`amountSpecified`|`int256`|Negative = exact input, positive = exact output.|
|`hookData`|`bytes`|Empty bytes or a hook-specific payload.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`quoteAmount`|`uint256`|For exact input, expected output. For exact output, expected input.|


### isLive

Whether the hook is generally live and accepting swaps.


```solidity
function isLive() external view returns (bool);
```

### maxGas

Declared maximum gas for getIndicativeQuote execution.


```solidity
function maxGas() external view returns (uint32);
```

### swapToPrice

Simulate a swap up to a target price.

Returns (0, 0) when price-bounded simulation is unsupported.


```solidity
function swapToPrice(
    PoolKey calldata key,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata hookData
) external view returns (uint256 amountIn, uint256 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool key.|
|`zeroForOne`|`bool`|Swap direction.|
|`amountSpecified`|`int256`|Negative = exact input, positive = exact output.|
|`sqrtPriceLimitX96`|`uint160`|Target Q64.96 sqrt price.|
|`hookData`|`bytes`|Empty bytes or a hook-specific payload.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Input consumed, including fees.|
|`amountOut`|`uint256`|Output received.|


