# ITempoExchange
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/0a9543d023e4a9afc81334cdd79c203f8feab340/src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol)

**Title:**
ITempoExchange

Interface for Tempo's enshrined stablecoin DEX

Tempo uses uint128 for amounts, not uint256. All stablecoins use 6 decimals.

The exchange is a precompiled contract at a fixed address on Tempo chain.


## Functions
### swapExactAmountIn

Executes a swap with an exact input amount


```solidity
function swapExactAmountIn(address tokenIn, address tokenOut, uint128 amountIn, uint128 minAmountOut)
    external
    returns (uint128 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIn`|`address`|The address of the input token|
|`tokenOut`|`address`|The address of the output token|
|`amountIn`|`uint128`|The exact amount of input tokens to swap|
|`minAmountOut`|`uint128`|The minimum amount of output tokens to receive (slippage protection)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountOut`|`uint128`|The amount of output tokens received|


### swapExactAmountOut

Executes a swap with an exact output amount


```solidity
function swapExactAmountOut(address tokenIn, address tokenOut, uint128 amountOut, uint128 maxAmountIn)
    external
    returns (uint128 amountIn);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIn`|`address`|The address of the input token|
|`tokenOut`|`address`|The address of the output token|
|`amountOut`|`uint128`|The exact amount of output tokens to receive|
|`maxAmountIn`|`uint128`|The maximum amount of input tokens to spend (slippage protection)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint128`|The amount of input tokens spent|


### quoteSwapExactAmountIn

Calculates the expected output amount for an exact input swap


```solidity
function quoteSwapExactAmountIn(address tokenIn, address tokenOut, uint128 amountIn)
    external
    view
    returns (uint128 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIn`|`address`|The address of the input token|
|`tokenOut`|`address`|The address of the output token|
|`amountIn`|`uint128`|The amount of input tokens|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountOut`|`uint128`|The expected amount of output tokens|


### quoteSwapExactAmountOut

Calculates the required input amount for an exact output swap


```solidity
function quoteSwapExactAmountOut(address tokenIn, address tokenOut, uint128 amountOut)
    external
    view
    returns (uint128 amountIn);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIn`|`address`|The address of the input token|
|`tokenOut`|`address`|The address of the output token|
|`amountOut`|`uint128`|The desired amount of output tokens|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint128`|The required amount of input tokens|


