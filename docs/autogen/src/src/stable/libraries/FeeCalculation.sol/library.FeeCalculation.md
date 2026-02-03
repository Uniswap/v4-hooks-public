# FeeCalculation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/c8d33770d8ba5213d85d21e19098c0bee166f83b/src/stable/libraries/FeeCalculation.sol)

**Title:**
FeeCalculation

Library providing core mathematical functions for calculating dynamic swap fees


## State Variables
### MAX_OPTIMAL_FEE_RATE
Maximum allowed optimal fee rate

Optimal fee rate must be strictly less than PPM (100%).


```solidity
uint24 public constant MAX_OPTIMAL_FEE_RATE = PPM - 1
```


### ONE
Fixed-point scalar used for precision where 1e12 == 100%.


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

Calculate the price ratio between two sqrt prices in Q96 format

Always returns min(price1, price2) / max(price1, price2), ensuring result <= 2^96


```solidity
function calculatePriceRatioX96(uint160 sqrtPrice1X96, uint160 sqrtPrice2X96)
    internal
    pure
    returns (uint160 priceRatioX96);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sqrtPrice1X96`|`uint160`|First sqrt price in Q96 format|
|`sqrtPrice2X96`|`uint160`|Second sqrt price in Q96 format|

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
|`priceRatioX96`|`uint160`|Price ratio in Q96 format from calculatePriceRatioX96, must be >= Q96|
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


### calculateFarFee

Calculate far fee - the fee that would place the effective price exactly at the "far" boundary.
The far boundary is whichever edge of the optimal rate is farthest from the current AMM price.


```solidity
function calculateFarFee(uint160 priceRatioX96, uint24 optimalFeeRate) internal pure returns (uint40 farFee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint160`|Price ratio in Q96 format from calculatePriceRatioX96, must be >= Q96|
|`optimalFeeRate`|`uint24`|Optimal fee rate in parts per million|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`farFee`|`uint40`|Fee to get to the "far" boundary|


### adjustPreviousFeeForPriceMovement

Adjust previous fee for price movement

When price moves further from reference, adjust the previous fee to account for the movement


```solidity
function adjustPreviousFeeForPriceMovement(uint160 priceRatioX96, uint40 previousFee)
    internal
    pure
    returns (uint40 adjustedFee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint160`|Price ratio in Q96 format from calculatePriceRatioX96, must be >= Q96|
|`previousFee`|`uint40`|Previous flexible fee|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`adjustedFee`|`uint40`|Adjusted previous fee accounting for price movement|


### calculateFlexibleFee

Calculate flexible fee with exponential decay

Fee decays from previous fee toward target fee over time


```solidity
function calculateFlexibleFee(uint40 targetFee, uint40 previousFee, uint256 k, uint256 logK, uint256 blocksPassed)
    internal
    pure
    returns (uint40 flexibleFee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`targetFee`|`uint40`|Target fee to decay toward|
|`previousFee`|`uint40`|Previous flexible fee|
|`k`|`uint256`|Decay constant in Q24 format (e.g., 16_609_443 for k=0.99)|
|`logK`|`uint256`|Natural log of k scaled appropriately|
|`blocksPassed`|`uint256`|Number of blocks since last fee update|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`flexibleFee`|`uint40`|New flexible fee after decay|


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


