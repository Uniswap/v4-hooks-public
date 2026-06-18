# IDexCallback
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0c68c6912ec9b3df692fd62740997db52f245b7d/src/aggregator-hooks/implementations/FluidDexT1/interfaces/IDexCallback.sol)

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


