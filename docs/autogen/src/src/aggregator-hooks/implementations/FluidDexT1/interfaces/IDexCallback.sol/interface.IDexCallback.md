# IDexCallback
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/1f52c3f85ae2e6c0f55bd2f364a64854ec0b34bc/src/aggregator-hooks/implementations/FluidDexT1/interfaces/IDexCallback.sol)

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


