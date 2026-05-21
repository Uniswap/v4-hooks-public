# IDexCallback
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/fb38bd58a3855b38f1e6e41a9ca471e83744f2b7/src/aggregator-hooks/implementations/FluidDexT1/interfaces/IDexCallback.sol)

**Title:**
IDexCallback

Callback interface required by Fluid DEX v1 "withCallback" swaps


## Functions
### dexCallback

dex liquidity callback


```solidity
function dexCallback(address token_, uint256 amount_) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token_`|`address`|The token being transferred|
|`amount_`|`uint256`|The amount being transferred|


