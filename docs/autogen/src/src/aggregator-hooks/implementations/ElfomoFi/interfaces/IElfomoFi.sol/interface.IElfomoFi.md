# IElfomoFi
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/03c6c317e620e2eb32675653ad26bf7faacc5605/src/aggregator-hooks/implementations/ElfomoFi/interfaces/IElfomoFi.sol)

**Title:**
IElfomoFi

Interface for ElfomoFi: a singleton PropAMM router with offchain-streamed quotes

Lives at 0xf0f0F0F0FB0d738452EfD03A28e8be14C76d5f73 on Base and BSC.
Mirrors the relevant subset of the deployed ElfomoFi contract surface.


## Functions
### getAmountOut

Get the expected output amount for an exact-input swap.


```solidity
function getAmountOut(address fromToken, address toToken, uint256 fromAmount)
    external
    view
    returns (uint256 toAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`fromToken`|`address`|The token to spend.|
|`toToken`|`address`|The token to receive.|
|`fromAmount`|`uint256`|Amount of `fromToken` to spend, in token base units.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`toAmount`|`uint256`|Expected amount of `toToken` received, in token base units.|


### getAmountIn

Get the required input amount for an exact-output swap.


```solidity
function getAmountIn(address fromToken, address toToken, uint256 toAmount)
    external
    view
    returns (uint256 fromAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`fromToken`|`address`|The token to spend.|
|`toToken`|`address`|The token to receive.|
|`toAmount`|`uint256`|Desired amount of `toToken`, in token base units.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`fromAmount`|`uint256`|Required amount of `fromToken`, in token base units.|


### getSupportedPairs

Get the full list of token pairs currently supported by ElfomoFi.


```solidity
function getSupportedPairs() external view returns (TokenPair[] memory);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`TokenPair[]`|The list of supported pairs (order is ElfomoFi-defined).|


### swapWithCallback

Swap tokens without prior approval; ElfomoFi pulls `fromToken` from `msg.sender` via the callback.


```solidity
function swapWithCallback(
    address fromToken,
    address toToken,
    int256 specifiedAmount,
    uint256 limitAmount,
    address receiver,
    uint256 partnerId,
    bytes calldata callbackData
) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`fromToken`|`address`|The address of the token to swap from.|
|`toToken`|`address`|The address of the token to swap to.|
|`specifiedAmount`|`int256`|Positive for exact input in `fromToken`, negative for exact output in `toToken`.|
|`limitAmount`|`uint256`|Minimum `toAmount` for exact input, maximum `fromAmount` for exact output. Use `0` to skip the exact-output limit check.|
|`receiver`|`address`|The address to receive the `toToken`.|
|`partnerId`|`uint256`|Partner identifier for rebates/tracking, `0` if not used.|
|`callbackData`|`bytes`|Opaque bytes passed through to the callback on `msg.sender`.|


## Events
### PairAdded
Emitted when ElfomoFi registers a new supported token pair.


```solidity
event PairAdded(address tokenA, address tokenB);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenA`|`address`|One side of the newly-supported pair.|
|`tokenB`|`address`|The other side of the newly-supported pair.|

### ElfomoTrade
Emitted when ElfomoFi executes a swap.


```solidity
event ElfomoTrade(
    uint256 indexed quoteId,
    uint256 indexed partnerId,
    address executor,
    address receiver,
    address fromToken,
    address toToken,
    uint256 fromAmount,
    uint256 toAmount
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`quoteId`|`uint256`|The pricing oracle's quote identifier consumed by the swap.|
|`partnerId`|`uint256`|Partner identifier supplied by the caller for rebate tracking.|
|`executor`|`address`|The `msg.sender` of the swap call.|
|`receiver`|`address`|The recipient of `toToken`.|
|`fromToken`|`address`|The token spent on the swap.|
|`toToken`|`address`|The token received from the swap.|
|`fromAmount`|`uint256`|Amount of `fromToken` actually paid, in token base units.|
|`toAmount`|`uint256`|Amount of `toToken` actually received, in token base units.|

## Errors
### InsufficientAmount
Thrown when the realized swap amount violates the caller's limit
(exact-in: realized output below `limitAmount`; exact-out: realized input above `limitAmount`).


```solidity
error InsufficientAmount(uint256 limitAmount, uint256 actualAmount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`limitAmount`|`uint256`|The caller-supplied limit, in token base units.|
|`actualAmount`|`uint256`|The realized amount that violated the limit, in token base units.|

### ExecutionFailed
Thrown when the pricing oracle returns a zero amount for the requested swap.


```solidity
error ExecutionFailed();
```

### ZeroBalance
Thrown when `swapWithContractBalance` is called while the contract holds zero `fromToken`.


```solidity
error ZeroBalance();
```

## Structs
### TokenPair
A pair supported by ElfomoFi's pricing oracle.


```solidity
struct TokenPair {
    address tokenA;
    address tokenB;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`tokenA`|`address`|One side of the pair (order is ElfomoFi-defined, not necessarily sorted).|
|`tokenB`|`address`|The other side of the pair.|

