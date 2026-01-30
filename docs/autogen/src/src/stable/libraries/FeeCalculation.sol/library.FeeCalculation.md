# FeeCalculation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/f1e6f575bfe1e9a74ff4f8105848ddf85efaaa12/src/stable/libraries/FeeCalculation.sol)

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


### calculateFarFee

Calculate far fee - the fee that would place the effective price exactly at the "far" boundary.
The far boundary is whichever edge of the optimal rate is farthest from the current AMM price.


```solidity
function calculateFarFee(uint160 priceRatioX96, uint24 optimalFeeRate) internal pure returns (uint40 farFee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`priceRatioX96`|`uint160`|Price ratio in Q96 format from calculatePriceRatioX96|
|`optimalFeeRate`|`uint24`|Optimal fee rate in parts per million|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`farFee`|`uint40`|Fee to get to the "far" boundary|


### adjustPreviousFeeForPriceMovement

Adjust previous fee for price movement

When price moves further from reference, adjust the previous fee to account for the movement


```solidity
function adjustPreviousFeeForPriceMovement(
    uint40 previousFee,
    uint160 sqrtAmmPriceX96,
    uint160 previousSqrtAmmPriceX96,
    bool ammPriceToTheLeft
) internal pure returns (uint40 adjustedFee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`previousFee`|`uint40`|Previous flexible fee|
|`sqrtAmmPriceX96`|`uint160`|Current AMM sqrt price|
|`previousSqrtAmmPriceX96`|`uint160`|Previous AMM sqrt price|
|`ammPriceToTheLeft`|`bool`|True if current AMM price < reference price|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`adjustedFee`|`uint40`|Adjusted previous fee accounting for price movement|


### calculateDecayFactor

Calculate exponential decay factor for fee reduction over time

Uses fast computation for small block counts, exponential for large


```solidity
function calculateDecayFactor(uint256 k, uint256 logK, uint256 blocksPassed)
    internal
    pure
    returns (uint256 factorX24);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`k`|`uint256`|Decay constant in Q24 format (e.g., 16_609_443 for k=0.99)|
|`logK`|`uint256`|Natural log of k scaled appropriately|
|`blocksPassed`|`uint256`|Number of blocks since last fee update|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`factorX24`|`uint256`|Decay factor in Q24 format (2^24 = no decay, 0 = full decay)|


### calculateFlexibleFeeWithDecay

Calculate flexible fee with exponential decay

Fee decays from previous fee toward target fee over time


```solidity
function calculateFlexibleFeeWithDecay(uint40 targetFee, uint40 previousFee, uint256 factorX24)
    internal
    pure
    returns (uint40 flexibleFee);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`targetFee`|`uint40`|Target fee to decay toward|
|`previousFee`|`uint40`|Previous flexible fee|
|`factorX24`|`uint256`|Decay factor in Q24 format from calculateDecayFactor|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`flexibleFee`|`uint40`|New flexible fee after decay|


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


