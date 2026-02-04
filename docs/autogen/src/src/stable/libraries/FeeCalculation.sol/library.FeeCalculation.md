# FeeCalculation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/212d67197db95402e0c7050941534ae8c084bb31/src/stable/libraries/FeeCalculation.sol)

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

Calculate the price ratio between two sqrt prices in Q96 format

Always returns min(price1, price2) / max(price1, price2), ensuring result <= 2^96


```solidity
function calculatePriceRatioX96(uint256 sqrtPrice1X96, uint256 sqrtPrice2X96)
    internal
    pure
    returns (uint256 priceRatioX96);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sqrtPrice1X96`|`uint256`|First sqrt price in Q96 format|
|`sqrtPrice2X96`|`uint256`|Second sqrt price in Q96 format|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format, always <= 2^96|


### calculateCloseFee

Calculate close fee - the fee that would place the effective price exactly at the "close" boundary.
The close boundary is whichever edge of the optimal rate is nearest to the current AMM price.


```solidity
function calculateCloseFee(uint256 priceRatioX96, uint256 optimalFeeE6) internal pure returns (int256 closeFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format from calculatePriceRatioX96, must be >= Q96|
|`optimalFeeE6`|`uint256`|Optimal fee rate in parts per million (e.g., 90 = 0.009%). Cannot be >= 1e6.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`closeFeeE12`|`int256`|Fee at the "close" boundary in 1e12. If <= 0, price is inside optimal rate. If > 0, price is outside.|


### calculateInsideOptimalRateFee

Calculate fee when price is inside optimal rate


```solidity
function calculateInsideOptimalRateFee(
    uint256 priceRatioX96,
    uint256 optimalFeeE6,
    bool ammPriceToTheLeft,
    bool userSellsZeroForOne
) internal pure returns (uint256 feeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format|
|`optimalFeeE6`|`uint256`|Optimal fee rate in parts per million|
|`ammPriceToTheLeft`|`bool`|True if AMM price < reference price|
|`userSellsZeroForOne`|`bool`|True if user is selling token0 for token1|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`feeE12`|`uint256`|Calculated fee in 1e12 precision|


### calculateFarFee

Calculate far fee - the fee that would place the effective price exactly at the "far" boundary.
The far boundary is whichever edge of the optimal rate is farthest from the current AMM price.


```solidity
function calculateFarFee(uint256 priceRatioX96, uint256 optimalFeeE6) internal pure returns (uint256 farFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format from calculatePriceRatioX96, must be >= Q96|
|`optimalFeeE6`|`uint256`|Optimal fee rate in parts per million|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`farFeeE12`|`uint256`|Fee to get to the "far" boundary in 1e12 precision|


### adjustPreviousFeeForPriceMovement

Adjust previous fee for price movement

When price moves further from reference, adjust the previous fee to account for the movement


```solidity
function adjustPreviousFeeForPriceMovement(uint256 priceRatioX96, uint256 previousFeeE12)
    internal
    pure
    returns (uint256 adjustedFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format from calculatePriceRatioX96, must be >= Q96|
|`previousFeeE12`|`uint256`|Previous flexible fee in 1e12 precision|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`adjustedFeeE12`|`uint256`|Adjusted previous fee accounting for price movement in 1e12 precision|


### calculateFlexibleFee

Calculate flexible fee with exponential decay

Fee decays from previous fee toward target fee over time


```solidity
function calculateFlexibleFee(
    uint256 targetFeeE12,
    uint256 previousFeeE12,
    uint256 k,
    uint256 logK,
    uint256 blocksPassed
) internal pure returns (uint256 flexibleFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`targetFeeE12`|`uint256`|Target fee to decay toward in 1e12 precision|
|`previousFeeE12`|`uint256`|Previous flexible fee in 1e12 precision|
|`k`|`uint256`|Decay constant in Q24 format (e.g., 16_609_443 for k=0.99)|
|`logK`|`uint256`|Natural log of k scaled appropriately|
|`blocksPassed`|`uint256`|Number of blocks since last fee update|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`flexibleFeeE12`|`uint256`|New flexible fee after decay in 1e12 precision|


### fastPow

Calculate the fast power of k to the power of blocksPassed


```solidity
function fastPow(uint256 k, uint256 blocksPassed) internal pure returns (uint256 z);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`k`|`uint256`|The base of the power|
|`blocksPassed`|`uint256`|The power to raise k to. Must be <= 4.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`z`|`uint256`|The result of k to the power of blocksPassed|


