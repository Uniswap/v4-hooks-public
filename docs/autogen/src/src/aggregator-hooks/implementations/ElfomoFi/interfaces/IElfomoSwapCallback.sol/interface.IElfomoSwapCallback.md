# IElfomoSwapCallback
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/03c6c317e620e2eb32675653ad26bf7faacc5605/src/aggregator-hooks/implementations/ElfomoFi/interfaces/IElfomoSwapCallback.sol)

**Title:**
IElfomoSwapCallback

Implement this interface to receive callbacks from `ElfomoFi.swapWithCallback`

Matches the signature on the deployed `ElfomoFi` contract; the callback must transfer
`uint256(fromTokenDelta)` of `fromToken` to `msg.sender` (the ElfomoFi contract) before returning.


## Functions
### elfomoSwapCallback

Called by ElfomoFi after the output side of a swap has been delivered to `receiver`


```solidity
function elfomoSwapCallback(int256 fromTokenDelta, int256 toTokenDelta, bytes calldata data) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`fromTokenDelta`|`int256`|Amount of `fromToken` the callee owes to the ElfomoFi contract (positive)|
|`toTokenDelta`|`int256`|Amount of `toToken` that was sent to the receiver (negative)|
|`data`|`bytes`|The opaque bytes passed into `ElfomoFi.swapWithCallback`|


