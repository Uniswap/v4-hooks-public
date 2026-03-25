# IDexCallback
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/0a9543d023e4a9afc81334cdd79c203f8feab340/src/aggregator-hooks/implementations/FluidDexT1/interfaces/IDexCallback.sol)

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


