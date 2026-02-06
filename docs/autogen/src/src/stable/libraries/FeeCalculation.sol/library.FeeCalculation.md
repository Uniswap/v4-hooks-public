# FeeCalculation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/07fec24f094c79e6a5b292ffc2d378f074af31bb/src/stable/libraries/FeeCalculation.sol)

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


### UNDEFINED_DECAYING_FEE_E12
Sentinel: no decaying fee (inside optimal range).


```solidity
uint256 internal constant UNDEFINED_DECAYING_FEE_E12 = ONE_E12 + 1
```


### Q48
Scale used to preserve precision in sqrt ratio math.


```solidity
uint256 internal constant Q48 = 2 ** 48
```


## Functions
### calculatePriceRatioX96

Calculate the price ratio between two sqrt prices in Q96 format, ensuring result <= 2^96


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


### calculateCloseBoundaryFee

Calculate close boundary fee - measures the fee to reach the close boundary of the optimal range.
Returns a fee metric where negative values mean inside the range, positive means outside.


```solidity
function calculateCloseBoundaryFee(uint256 priceRatioX96, uint256 optimalFeeE6)
    internal
    pure
    returns (int256 closeBoundaryFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio to reference price in Q96 format from calculatePriceRatioX96|
|`optimalFeeE6`|`uint256`|Optimal fee in parts per million (e.g., 90 = 0.009%). Cannot be >= 1e6.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`closeBoundaryFeeE12`|`int256`|Close boundary fee. If <= 0, price is inside optimal range. If > 0, price is outside.|


### calculateInsideOptimalRangeFee

Calculate fee when price is inside optimal range


```solidity
function calculateInsideOptimalRangeFee(
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
|`optimalFeeE6`|`uint256`|Optimal fee in parts per million|
|`ammPriceToTheLeft`|`bool`|True if AMM price < reference price|
|`userSellsZeroForOne`|`bool`|True if user is selling token0 for token1|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`feeE12`|`uint256`|Calculated fee in 1e12 precision|


### calculateFarBoundaryFee

Calculate far boundary fee - the fee that would place the effective price exactly at the "far" boundary.
The far boundary is whichever edge of the optimal range is farthest from the current AMM price.


```solidity
function calculateFarBoundaryFee(uint256 priceRatioX96, uint256 optimalFeeE6)
    internal
    pure
    returns (uint256 farBoundaryFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format from calculatePriceRatioX96, must be <= Q96|
|`optimalFeeE6`|`uint256`|Optimal fee in parts per million|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`farBoundaryFeeE12`|`uint256`|Fee to get to the "far" boundary in 1e12 precision|


### adjustPreviousFeeForPriceMovement

Adjust previous fee to preserve the same effective price when AMM price moves further from reference


```solidity
function adjustPreviousFeeForPriceMovement(uint256 priceRatioX96, uint256 previousFeeE12)
    internal
    pure
    returns (uint256 adjustedFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint256`|Price ratio in Q96 format from calculatePriceRatioX96 (always <= Q96 since it's min/max)|
|`previousFeeE12`|`uint256`|Previous flexible fee in 1e12 precision|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`adjustedFeeE12`|`uint256`|Adjusted previous fee accounting for price movement in 1e12 precision|


### calculateDecayingFee

Calculate flexible fee with exponential decay. Fee decays from previous fee toward target fee over time.


```solidity
function calculateDecayingFee(
    uint256 targetFeeE12,
    uint256 previousFeeE12,
    uint256 k,
    uint256 logK,
    uint256 blocksPassed
) internal pure returns (uint256 decayingFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`targetFeeE12`|`uint256`|Target fee to decay toward in 1e12 precision|
|`previousFeeE12`|`uint256`|Previous flexible fee in 1e12 precision, previousFee >= targetFee|
|`k`|`uint256`|Decay constant in Q24 format (e.g., 16_609_443 for k=0.99), <= Q24|
|`logK`|`uint256`|Natural log of k scaled appropriately|
|`blocksPassed`|`uint256`|Number of blocks since last fee update, <= type(uint40).max|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`decayingFeeE12`|`uint256`|New flexible fee after decay in 1e12 precision|


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


