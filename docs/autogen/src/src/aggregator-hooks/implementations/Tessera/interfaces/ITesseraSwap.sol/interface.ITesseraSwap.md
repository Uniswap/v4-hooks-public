# ITesseraSwap
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/03c6c317e620e2eb32675653ad26bf7faacc5605/src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraSwap.sol)

**Title:**
ITesseraSwap

Interface for the TesseraSwap PropAMM router

Lives at 0x55555522005BcAE1c2424D474BfD5ed477749E3e on Base and BSC.
`amountSpecified` follows Tessera's convention: positive = exact input, negative = exact output
(the inverse of Uniswap V4's convention).


## Functions
### tesseraSwapViewAmounts

View-quote for a swap. Returns the same `(amountIn, amountOut)` the matching execution
call would produce in the same block.


```solidity
function tesseraSwapViewAmounts(address tokenIn, address tokenOut, int256 amountSpecified)
    external
    view
    returns (uint256 amountIn, uint256 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIn`|`address`|The address of the token being spent.|
|`tokenOut`|`address`|The address of the token being received.|
|`amountSpecified`|`int256`|Positive for exact input, negative for exact output (Tessera convention).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of `tokenIn` that would be consumed, in token base units.|
|`amountOut`|`uint256`|Amount of `tokenOut` that would be delivered, in token base units.|


### tesseraSwapWithAllowances

Approval-based swap entrypoint; assumes `msg.sender` has approved `tokenIn` to TesseraSwap.


```solidity
function tesseraSwapWithAllowances(
    address tokenIn,
    address tokenOut,
    int256 amountSpecified,
    uint256 amountCheck,
    address recipient,
    bytes calldata swapData
) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIn`|`address`|The address of the token being spent.|
|`tokenOut`|`address`|The address of the token being received.|
|`amountSpecified`|`int256`|Positive for exact input, negative for exact output (Tessera convention).|
|`amountCheck`|`uint256`|Min `amountOut` for exact input, max `amountIn` for exact output.|
|`recipient`|`address`|The address to receive `tokenOut`.|
|`swapData`|`bytes`|Engine-specific routing payload (use empty bytes for default routing).|


### tesseraSwapWithCallback

Callback-based swap entrypoint; TesseraSwap pulls `tokenIn` from `msg.sender` via the callback.


```solidity
function tesseraSwapWithCallback(
    address tokenIn,
    address tokenOut,
    int256 amountSpecified,
    uint256 amountCheck,
    address recipient,
    bytes calldata callbackData,
    bytes calldata swapData
) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIn`|`address`|The address of the token being spent.|
|`tokenOut`|`address`|The address of the token being received.|
|`amountSpecified`|`int256`|Positive for exact input, negative for exact output (Tessera convention).|
|`amountCheck`|`uint256`|Min `amountOut` for exact input, max `amountIn` for exact output.|
|`recipient`|`address`|The address to receive `tokenOut`.|
|`callbackData`|`bytes`|Opaque bytes passed through to `tesseraSwapCallback` on `msg.sender`.|
|`swapData`|`bytes`|Engine-specific routing payload (use empty bytes for default routing).|


## Events
### TesseraTrade
Emitted when TesseraSwap settles a trade through its engine.


```solidity
event TesseraTrade(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIn`|`address`|The token spent by `msg.sender`.|
|`tokenOut`|`address`|The token delivered to `recipient`.|
|`amountIn`|`uint256`|Amount of `tokenIn` consumed, in token base units.|
|`amountOut`|`uint256`|Amount of `tokenOut` delivered, in token base units.|
|`recipient`|`address`|The recipient of `tokenOut`.|

