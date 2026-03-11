# IFluidDexT1
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/17d7d5811380e775c83dd0663f30fb95c53d02b9/src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol)

**Title:**
IFluidDexT1

Interface for the Fluid DEX T1 pool (colloquially Fluid DEX v1)


## Functions
### swapIn

Executes a swap with an exact input amount


```solidity
function swapIn(bool swap0to1_, uint256 amountIn_, uint256 amountOutMin_, address to_)
    external
    payable
    returns (uint256 amountOut_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`swap0to1_`|`bool`|Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0|
|`amountIn_`|`uint256`|The exact amount of input tokens to swap|
|`amountOutMin_`|`uint256`|The minimum amount of output tokens the user is willing to accept|
|`to_`|`address`|The recipient address for the output tokens|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountOut_`|`uint256`|The amount of output tokens received from the swap|


### swapOut

Executes a swap with an exact output amount


```solidity
function swapOut(bool swap0to1_, uint256 amountOut_, uint256 amountInMax_, address to_)
    external
    payable
    returns (uint256 amountIn_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`swap0to1_`|`bool`|Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0|
|`amountOut_`|`uint256`|The exact amount of output tokens to receive|
|`amountInMax_`|`uint256`|The maximum amount of input tokens the user is willing to spend|
|`to_`|`address`|The recipient address for the output tokens|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn_`|`uint256`|The amount of input tokens used for the swap|


### swapInWithCallback

Executes a swap with an exact input amount using a callback for token transfer

The caller must implement IFluidDexCallback to provide the input tokens


```solidity
function swapInWithCallback(bool swap0to1_, uint256 amountIn_, uint256 amountOutMin_, address to_)
    external
    payable
    returns (uint256 amountOut_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`swap0to1_`|`bool`|Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0|
|`amountIn_`|`uint256`|The exact amount of input tokens to swap|
|`amountOutMin_`|`uint256`|The minimum amount of output tokens the user is willing to accept|
|`to_`|`address`|The recipient address for the output tokens|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountOut_`|`uint256`|The amount of output tokens received from the swap|


### swapOutWithCallback

Executes a swap with an exact output amount using a callback for token transfer

The caller must implement IFluidDexCallback to provide the input tokens


```solidity
function swapOutWithCallback(bool swap0to1_, uint256 amountOut_, uint256 amountInMax_, address to_)
    external
    payable
    returns (uint256 amountIn_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`swap0to1_`|`bool`|Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0|
|`amountOut_`|`uint256`|The exact amount of output tokens to receive|
|`amountInMax_`|`uint256`|The maximum amount of input tokens the user is willing to spend|
|`to_`|`address`|The recipient address for the output tokens|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn_`|`uint256`|The amount of input tokens used for the swap|


## Structs
### CollateralReserves

```solidity
struct CollateralReserves {
    uint256 token0RealReserves;
    uint256 token1RealReserves;
    uint256 token0ImaginaryReserves;
    uint256 token1ImaginaryReserves;
}
```

### DebtReserves

```solidity
struct DebtReserves {
    uint256 token0Debt;
    uint256 token1Debt;
    uint256 token0RealReserves;
    uint256 token1RealReserves;
    uint256 token0ImaginaryReserves;
    uint256 token1ImaginaryReserves;
}
```

