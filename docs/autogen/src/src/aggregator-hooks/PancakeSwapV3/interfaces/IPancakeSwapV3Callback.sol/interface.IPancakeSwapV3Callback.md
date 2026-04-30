# IPancakeSwapV3Callback
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/d636b0c2e723a4f3e275fde691adb8ea9a34eb83/src/aggregator-hooks/PancakeSwapV3/interfaces/IPancakeSwapV3Callback.sol)

**Title:**
IPancakeSwapV3Callback

Callback from PancakeSwap V3 compatible pools during swap (matches `IPancakeV3SwapCallback` on-chain name)


## Functions
### pancakeV3SwapCallback

Called to `msg.sender` after executing a swap on the pool


```solidity
function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount0Delta`|`int256`|Owed amount of token0: pay pool if positive, receive from pool if negative|
|`amount1Delta`|`int256`|Owed amount of token1: pay pool if positive, receive from pool if negative|
|`data`|`bytes`|Arbitrary data forwarded from the `swap` call, e.g. payer routing|


