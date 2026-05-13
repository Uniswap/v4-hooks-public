# IUniswapV3Pool
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/2be48d7f4fbdc30390a03b6da2febe82639b089c/src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3Pool.sol)

Minimal Uniswap V3 compatible pool interface


## Functions
### token0

First token of the pool by address sort order


```solidity
function token0() external view returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|Token address of token0|


### token1

Second token of the pool by address sort order


```solidity
function token1() external view returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|Token address of token1|


### fee

Swap fee of the pool, in hundredths of a bip (i.e. 1e6 = 100%)


```solidity
function fee() external view returns (uint24);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint24`|Fee tier identifier|


### tickSpacing

Minimum number of ticks between initialized ticks


```solidity
function tickSpacing() external view returns (int24);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int24`|Spacing between usable ticks|


### swap

Execute a swap against the pool


```solidity
function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
) external returns (int256 amount0, int256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`recipient`|`address`|Address that receives the output of the swap|
|`zeroForOne`|`bool`|When true, swap token0 for token1; when false, token1 for token0|
|`amountSpecified`|`int256`|Amount of swap: exact input is positive, exact output is negative (periphery-style)|
|`sqrtPriceLimitX96`|`uint160`|Price limit for the swap (Q64.96); pool price will not cross this bound|
|`data`|`bytes`|Opaque bytes passed through to `IUniswapV3SwapCallback.uniswapV3SwapCallback`|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`int256`|Delta of the pool's token0 balance (negative if pool received token0)|
|`amount1`|`int256`|Delta of the pool's token1 balance (negative if pool received token1)|


