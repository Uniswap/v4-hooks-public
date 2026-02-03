# FeeCalculation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/bc61b69dbabe6bb31bf5ca2c5c42140a7cb4f0cc/src/stable/libraries/FeeCalculation.sol)

**Title:**
FeeCalculation

Library providing core mathematical functions for calculating dynamic swap fees


## State Variables
### ONE_E6
Scalar for pips precision (1e6 = 100%)


```solidity
uint256 internal constant ONE_E6 = 1e6
```


### ONE_E12
Scalar for scaled precision (1e12 = 100%)


```solidity
uint256 internal constant ONE_E12 = 1e12
```


### UNDEFINED_FLEXIBLE_FEE_E12
Sentinel: no flexible fee (inside optimal rate)


```solidity
uint256 internal constant UNDEFINED_FLEXIBLE_FEE_E12 = ONE_E12 + 1
```


### MAX_OPTIMAL_FEE_RATE_E6
Maximum allowed optimal fee rate in pips

Optimal fee rate must be strictly less than ONE_E6 (100%).


```solidity
uint256 public constant MAX_OPTIMAL_FEE_RATE_E6 = ONE_E6 - 1
```


### Q48
Scale used to preserve precision in sqrt ratio math.


```solidity
uint256 internal constant Q48 = 2 ** 48
```


## Functions
### calculatePriceRatioX96

Calculate the price ratio between AMM price and reference price in Q96 format


```solidity
function calculatePriceRatioX96(uint256 sqrtAmmPriceX96, uint256 sqrtReferencePriceX96)
    internal
    pure
    returns (uint256 priceRatioX96);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sqrtAmmPriceX96`|`uint256`|Current AMM sqrt price in Q96 format|
|`sqrtReferencePriceX96`|`uint256`|Reference sqrt price in Q96 format|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format, always <= 2^96|


### calculateCloseFee

Calculate close fee - the fee that would place the effective price exactly at the "close" boundary.
The close boundary is whichever edge of the optimal rate is nearest to the current AMM price.


```solidity
function calculateCloseFee(uint256 priceRatioX96, uint256 optimalFeeRateE6)
    internal
    pure
    returns (int256 closeFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format from calculatePriceRatioX96|
|`optimalFeeRateE6`|`uint256`|Optimal fee rate in parts per million (e.g., 90 = 0.009%). Cannot be >= 1e6.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`closeFeeE12`|`int256`|Fee at the "close" boundary in 1e12. If <= 0, price is inside optimal rate. If > 0, price is outside.|


### calculateInsideOptimalRateFee

Calculate fee when price is inside optimal rate


```solidity
function calculateInsideOptimalRateFee(
    uint256 priceRatioX96,
    uint256 optimalFeeRateE6,
    bool ammPriceToTheLeft,
    bool userSellsZeroForOne
) internal pure returns (uint256 feeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format|
|`optimalFeeRateE6`|`uint256`|Optimal fee rate in parts per million|
|`ammPriceToTheLeft`|`bool`|True if AMM price < reference price|
|`userSellsZeroForOne`|`bool`|True if user is selling token0 for token1|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`feeE12`|`uint256`|Calculated fee in 1e12 precision|


