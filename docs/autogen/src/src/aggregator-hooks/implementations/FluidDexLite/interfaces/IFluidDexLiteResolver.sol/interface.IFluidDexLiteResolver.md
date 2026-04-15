# IFluidDexLiteResolver
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/1f52c3f85ae2e6c0f55bd2f364a64854ec0b34bc/src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteResolver.sol)

**Title:**
IFluidDexLiteResolver

Interface for the Fluid DEX Lite resolver


## Functions
### getAllDexes

Returns all registered DEX pools


```solidity
function getAllDexes() external view returns (IFluidDexLite.DexKey[] memory);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IFluidDexLite.DexKey[]`|An array of DexKey structs identifying each pool|


### getDexState

Retrieves the current state configuration of a DEX pool


```solidity
function getDexState(IFluidDexLite.DexKey memory dexKey) external view returns (IFluidDexLite.DexState memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`dexKey`|`IFluidDexLite.DexKey`|The unique key identifying the DEX pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IFluidDexLite.DexState`|The current DexState including variables, shifts, and thresholds|


### getDexEntireData

Retrieves complete data for a DEX pool including state, prices, and reserves


```solidity
function getDexEntireData(IFluidDexLite.DexKey memory dexKey) external returns (IFluidDexLite.DexEntireData memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`dexKey`|`IFluidDexLite.DexKey`|The unique key identifying the DEX pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IFluidDexLite.DexEntireData`|Complete DexEntireData struct with all pool information|


### getPricesAndReserves

Retrieves current prices and reserves for a DEX pool


```solidity
function getPricesAndReserves(IFluidDexLite.DexKey memory dexKey)
    external
    returns (IFluidDexLite.Prices memory, IFluidDexLite.Reserves memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`dexKey`|`IFluidDexLite.DexKey`|The unique key identifying the DEX pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IFluidDexLite.Prices`|Prices struct with pool, center, range, and threshold prices|
|`<none>`|`IFluidDexLite.Reserves`|Reserves struct with real and imaginary reserves for both tokens|


### estimateSwapSingle

Estimates the result of a single-hop swap without executing it


```solidity
function estimateSwapSingle(IFluidDexLite.DexKey calldata dexKey, bool swap0To1, int256 amountSpecified)
    external
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`dexKey`|`IFluidDexLite.DexKey`|The unique key identifying the DEX pool|
|`swap0To1`|`bool`|Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0|
|`amountSpecified`|`int256`|The amount to swap. Positive for exact input, negative for exact output|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The estimated unspecified amount (output for exact-in, input for exact-out)|


### estimateSwapHop

Estimates the result of a multi-hop swap without executing it


```solidity
function estimateSwapHop(address[] calldata path, IFluidDexLite.DexKey[] calldata dexKeys, int256 amountSpecified)
    external
    view
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`path`|`address[]`|Array of token addresses representing the swap route|
|`dexKeys`|`IFluidDexLite.DexKey[]`|Array of DexKey structs for each hop in the route|
|`amountSpecified`|`int256`|The amount to swap. Positive for exact input, negative for exact output|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The estimated final output amount|


