# IFluidDexLiteCallback
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/17d7d5811380e775c83dd0663f30fb95c53d02b9/src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteCallback.sol)

**Title:**
IFluidDexLiteCallback

Callback interface required by Fluid DEX Lite swaps when isCallback is true


## Functions
### dexCallback

Called by Fluid DEX Lite to request token transfer from the caller

Must transfer exactly `amount_` of `token_` to msg.sender (the DEX)


```solidity
function dexCallback(address token_, uint256 amount_, bytes calldata data_) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token_`|`address`|The token address that must be transferred|
|`amount_`|`uint256`|The amount of tokens that must be transferred|
|`data_`|`bytes`|Arbitrary callback data passed through from the swap call|


