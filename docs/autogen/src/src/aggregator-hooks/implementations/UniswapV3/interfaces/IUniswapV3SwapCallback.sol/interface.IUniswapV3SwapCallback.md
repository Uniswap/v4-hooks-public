# IUniswapV3SwapCallback
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/d636b0c2e723a4f3e275fde691adb8ea9a34eb83/src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3SwapCallback.sol)

**Title:**
IUniswapV3SwapCallback

Callback from Uniswap V3 compatible pools during swap


## Functions
### uniswapV3SwapCallback

Called to `msg.sender` after executing a swap on the pool


```solidity
function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount0Delta`|`int256`|Owed amount of token0: pay pool if positive, receive from pool if negative|
|`amount1Delta`|`int256`|Owed amount of token1: pay pool if positive, receive from pool if negative|
|`data`|`bytes`|Arbitrary data forwarded from the `swap` call, e.g. payer routing|


