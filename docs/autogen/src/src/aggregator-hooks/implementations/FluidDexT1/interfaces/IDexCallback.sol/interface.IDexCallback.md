# IDexCallback
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/56f51601c343010d27d45c492f27de85ad1a03d2/src/aggregator-hooks/implementations/FluidDexT1/interfaces/IDexCallback.sol)

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


