# ICurveStableSwap
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/17d7d5811380e775c83dd0663f30fb95c53d02b9/src/aggregator-hooks/implementations/StableSwap/interfaces/IStableSwap.sol)

**Title:**
ICurveStableSwap

Interface for Curve StableSwap pools

We have to write our own interface file since the source code is in vyper


## Functions
### get_dy

Calculates the expected output amount for a swap


```solidity
function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`i`|`int128`|Index of the input token in the pool|
|`j`|`int128`|Index of the output token in the pool|
|`dx`|`uint256`|Amount of input tokens to swap|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The expected amount of output tokens|


### exchange

Executes a token swap


```solidity
function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`i`|`int128`|Index of the input token in the pool|
|`j`|`int128`|Index of the output token in the pool|
|`dx`|`uint256`|Amount of input tokens to swap|
|`min_dy`|`uint256`|Minimum amount of output tokens to receive (slippage protection)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The actual amount of output tokens received|


### coins

Returns the token address at a given index


```solidity
function coins(uint256 i) external view returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`i`|`uint256`|Index of the token in the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The token address at that index|


### balances

Returns the balance of a token at a given index


```solidity
function balances(uint256 i) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`i`|`uint256`|Index of the token in the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The balance of the token at that index|


