# FeeCalculation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/f4d8d22c12001671a333524cf0b44fc3fb5e13d3/src/stable/libraries/FeeCalculation.sol)

**Title:**
FeeCalculation

Library providing core mathematical functions for calculating dynamic swap fees


## State Variables
### MAX_FEE
Maximum supported fee in Uniswap format (990_000 = 99%)


```solidity
uint24 public constant MAX_FEE = 990_000
```


### MAX_OPTIMAL_FEE_RATE
Maximum allowed optimal fee rate

Optimal fee rate must be strictly less than PPM (100%).


```solidity
uint24 public constant MAX_OPTIMAL_FEE_RATE = PPM - 1
```


### ONE
Fixed-point scalar used for precisionwhere 1e12 == 100%.


```solidity
uint40 internal constant ONE = 1e12
```


### UNDEFINED_FLEXIBLE_FEE
Sentinel: no flexible fee (inside optimal rate).


```solidity
uint40 internal constant UNDEFINED_FLEXIBLE_FEE = ONE + 1
```


### PPM
Parts-per-million scalar (1e6 = 100%).


```solidity
uint24 internal constant PPM = 1e6
```


### Q48
Scale used to preserve precision in sqrt ratio math.


```solidity
uint64 internal constant Q48 = 2 ** 48
```


## Functions
### calculatePriceRatioX96

Calculate the price ratio between AMM price and reference price in Q96 format


```solidity
function calculatePriceRatioX96(uint160 sqrtAmmPriceX96, uint160 sqrtReferencePriceX96)
    internal
    pure
    returns (uint160 priceRatioX96);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sqrtAmmPriceX96`|`uint160`|Current AMM sqrt price in Q96 format|
|`sqrtReferencePriceX96`|`uint160`|Reference sqrt price in Q96 format|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint160`|Price ratio in Q96 format, always <= 2^96|


### calculateCloseFee

Calculate close fee - the fee that would place the effective price exactly at the "close" boundary.
The close boundary is whichever edge of the optimal rate is nearest to the current AMM price.


```solidity
function calculateCloseFee(uint160 priceRatioX96, uint24 optimalFeeRate) internal pure returns (int40 closeFee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint160`|Price ratio in Q96 format from calculatePriceRatioX96|
|`optimalFeeRate`|`uint24`|Optimal fee rate in parts per million (e.g., 90 = 0.009%). Cannot be >= 1e6.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`closeFee`|`int40`|Fee at the "close" boundary. If <= 0, price is inside optimal rate. If > 0, price is outside.|


### calculateInsideOptimalRateFee

Calculate fee when price is inside optimal rate


```solidity
function calculateInsideOptimalRateFee(
    uint160 priceRatioX96,
    uint24 optimalFeeRate,
    bool ammPriceToTheLeft,
    bool userSellsZeroForOne
) internal pure returns (uint40 fee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint160`|Price ratio in Q96 format|
|`optimalFeeRate`|`uint24`|Optimal fee rate in parts per million|
|`ammPriceToTheLeft`|`bool`|True if AMM price < reference price|
|`userSellsZeroForOne`|`bool`|True if user is selling token0 for token1|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`fee`|`uint40`|Calculated fee in 1e12 precision|


### convertToUniswapFee

Convert internal fee format to Uniswap fee format


```solidity
function convertToUniswapFee(uint40 internalFee) internal pure returns (uint24 uniswapFee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`internalFee`|`uint40`|Fee in internal format (1e12 = 100%)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`uniswapFee`|`uint24`|Fee in Uniswap format (1_000_000 = 100%, max 990_000)|


