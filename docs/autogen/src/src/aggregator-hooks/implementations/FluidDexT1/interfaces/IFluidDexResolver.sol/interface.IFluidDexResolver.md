# IFluidDexResolver
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/0a9543d023e4a9afc81334cdd79c203f8feab340/src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexResolver.sol)

**Title:**
IFluidDexResolver

Interface for the Fluid DEX T1 resolver


## Functions
### getDexTokens

Get the addresses of the tokens in a DEX


```solidity
function getDexTokens(address dex_) external view returns (address token0_, address token1_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`dex_`|`address`|The address of the DEX|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`token0_`|`address`|The address of token0 in the DEX|
|`token1_`|`address`|The address of token1 in the DEX|


### estimateSwapIn

estimates swap IN tokens execution


```solidity
function estimateSwapIn(address dex_, bool swap0to1_, uint256 amountIn_, uint256 amountOutMin_)
    external
    payable
    returns (uint256 amountOut_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`dex_`|`address`|Dex pool|
|`swap0to1_`|`bool`|Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0|
|`amountIn_`|`uint256`|The exact amount of input tokens to swap|
|`amountOutMin_`|`uint256`|The minimum amount of output tokens the user is willing to accept|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountOut_`|`uint256`|The amount of output tokens received from the swap|


### estimateSwapOut

estimates swap OUT tokens execution


```solidity
function estimateSwapOut(address dex_, bool swap0to1_, uint256 amountOut_, uint256 amountInMax_)
    external
    payable
    returns (uint256 amountIn_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`dex_`|`address`|Dex pool|
|`swap0to1_`|`bool`|Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0|
|`amountOut_`|`uint256`|The exact amount of tokens to receive after swap|
|`amountInMax_`|`uint256`|Maximum amount of tokens to swap in|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn_`|`uint256`|The amount of input tokens used for the swap|


