# ITesseraSwapCallback
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/03c6c317e620e2eb32675653ad26bf7faacc5605/src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraSwapCallback.sol)

**Title:**
ITesseraSwapCallback

Implement this interface to receive callbacks from `TesseraSwap.tesseraSwapWithCallback`

Matches the signature on the deployed `TesseraSwap` contract; the callback must transfer
`uint256(amountInDelta)` of `tokenIn` to `msg.sender` (the TesseraSwap contract) before returning.


## Functions
### tesseraSwapCallback

Called by TesseraSwap after the output side of a swap has been delivered to `recipient`


```solidity
function tesseraSwapCallback(int256 amountInDelta, int256 amountOutDelta, bytes calldata data) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amountInDelta`|`int256`|Amount of `tokenIn` the callee owes to the TesseraSwap contract (positive)|
|`amountOutDelta`|`int256`|Amount of `tokenOut` that was sent to the recipient (negative)|
|`data`|`bytes`|The opaque bytes passed into `TesseraSwap.tesseraSwapWithCallback`|


