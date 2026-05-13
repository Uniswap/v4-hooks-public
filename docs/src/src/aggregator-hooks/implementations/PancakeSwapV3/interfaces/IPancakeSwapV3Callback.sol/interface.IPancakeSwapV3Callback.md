# IPancakeSwapV3Callback
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/2be48d7f4fbdc30390a03b6da2febe82639b089c/src/aggregator-hooks/implementations/PancakeSwapV3/interfaces/IPancakeSwapV3Callback.sol)

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


