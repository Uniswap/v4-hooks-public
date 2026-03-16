# IFluidDexLite
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/269a4bc7c24c99a9bf6408262df37a462d8a2b9c/src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol)

**Title:**
IFluidDexLite

Interface for the Fluid DEX Lite pool


## Functions
### swapSingle

Executes a single-hop swap on the Fluid DEX Lite pool


```solidity
function swapSingle(
    DexKey calldata dexKey_,
    bool swap0To1_,
    int256 amountSpecified_,
    uint256 amountLimit_,
    address to_,
    bool isCallback_,
    bytes calldata callbackData_,
    bytes calldata extraData_
) external payable returns (uint256 amountUnspecified_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`dexKey_`|`DexKey`|The unique key identifying the DEX pool (token0, token1, salt)|
|`swap0To1_`|`bool`|Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0|
|`amountSpecified_`|`int256`|The amount to swap. Positive for exact input, negative for exact output|
|`amountLimit_`|`uint256`|Slippage protection. Min output for exact-in, max input for exact-out|
|`to_`|`address`|The recipient address for the output tokens|
|`isCallback_`|`bool`|If true, uses callback mechanism for token transfer instead of direct transfer|
|`callbackData_`|`bytes`|Arbitrary data passed to the callback function if isCallback_ is true|
|`extraData_`|`bytes`|Additional data for specialized swap logic|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountUnspecified_`|`uint256`|The unspecified amount (output for exact-in, input for exact-out)|


## Structs
### DexKey

```solidity
struct DexKey {
    address token0;
    address token1;
    bytes32 salt;
}
```

### DexState

```solidity
struct DexState {
    DexVariables dexVariables;
    CenterPriceShift centerPriceShift;
    RangeShift rangeShift;
    ThresholdShift thresholdShift;
}
```

### DexVariables

```solidity
struct DexVariables {
    uint256 fee;
    uint256 revenueCut;
    uint256 rebalancingStatus;
    bool isCenterPriceShiftActive;
    uint256 centerPrice;
    address centerPriceAddress;
    bool isRangePercentShiftActive;
    uint256 upperRangePercent;
    uint256 lowerRangePercent;
    bool isThresholdPercentShiftActive;
    uint256 upperShiftThresholdPercent;
    uint256 lowerShiftThresholdPercent;
    uint256 token0Decimals;
    uint256 token1Decimals;
    uint256 totalToken0AdjustedAmount;
    uint256 totalToken1AdjustedAmount;
}
```

### CenterPriceShift

```solidity
struct CenterPriceShift {
    uint256 lastInteractionTimestamp;
    uint256 rebalancingShiftingTime;
    uint256 maxCenterPrice;
    uint256 minCenterPrice;
    uint256 shiftPercentage;
    uint256 centerPriceShiftingTime;
    uint256 startTimestamp;
}
```

### RangeShift

```solidity
struct RangeShift {
    uint256 oldUpperRangePercent;
    uint256 oldLowerRangePercent;
    uint256 shiftingTime;
    uint256 startTimestamp;
}
```

### ThresholdShift

```solidity
struct ThresholdShift {
    uint256 oldUpperThresholdPercent;
    uint256 oldLowerThresholdPercent;
    uint256 shiftingTime;
    uint256 startTimestamp;
}
```

### Prices

```solidity
struct Prices {
    uint256 poolPrice;
    uint256 centerPrice;
    uint256 upperRangePrice;
    uint256 lowerRangePrice;
    uint256 upperThresholdPrice;
    uint256 lowerThresholdPrice;
}
```

### Reserves

```solidity
struct Reserves {
    uint256 token0RealReserves;
    uint256 token1RealReserves;
    uint256 token0ImaginaryReserves;
    uint256 token1ImaginaryReserves;
}
```

### ConstantViews

```solidity
struct ConstantViews {
    address liquidity;
    address deployer;
}
```

### DexEntireData

```solidity
struct DexEntireData {
    bytes8 dexId;
    DexKey dexKey;
    ConstantViews constantViews;
    Prices prices;
    Reserves reserves;
    DexState dexState;
}
```

