# Guidestar4Stable
[Git Source](https://github.com/Uniswap/v4-hooks/blob/af82e7dad988a6dbd52b8a924edb99094802d853/src/guidestar/Guidestar4Stable.sol)

**Inherits:**
[BaseGuidestarHook](/src/guidestar/BaseGuidestarHook.sol/abstract.BaseGuidestarHook.md)

**Title:**
Guidestar4Stable

A hook for stable pairs that allows for dynamic fees


## State Variables
### MAX_FEE
The maximum fee is 99%


```solidity
uint256 public constant MAX_FEE = 990_000
```


### Q48
Used for sqrt price ratio calculations


```solidity
uint256 internal constant Q48 = 2 ** 48
```


### Q96

```solidity
uint256 internal constant Q96 = 2 ** 96
```


### FEE_PRECISION

```solidity
uint256 internal constant FEE_PRECISION = 1e12
```


### FEE_DENOMINATOR
Denominator in pips used for fee calculations


```solidity
uint256 internal constant FEE_DENOMINATOR = 1e6
```


### UNDEFINED_FLEXIBLE_FEE

```solidity
uint256 internal constant UNDEFINED_FLEXIBLE_FEE = FEE_PRECISION + 1
```


### TO_UNISWAP_FEE

```solidity
uint256 internal constant TO_UNISWAP_FEE = FEE_PRECISION / 1e6
```


### poolStorage

```solidity
mapping(PoolId => PoolStorage) private poolStorage
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, address _initialOwner, address _gateway)
    BaseGuidestarHook(_poolManager, _initialOwner, _gateway);
```

### initializePair

Initializes a v4 pool and sets its fee data and hook params


```solidity
function initializePair(
    PoolKey calldata poolKey,
    uint160 sqrtPriceX96,
    FeeData memory feeData_,
    HookParams memory hookParams_
) external onlyOwner returns (int24 tick);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|the poolKey of the pool to initialize|
|`sqrtPriceX96`|`uint160`|the initial price of the pool to be set|
|`feeData_`|`FeeData`|the fee data for the poolKey|
|`hookParams_`|`HookParams`|the hook params for the poolKey|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tick`|`int24`|the tick of the new initialized pool|


### feeData

Gets the fee data for a given pool


```solidity
function feeData(PoolId poolId) external view returns (FeeData memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`FeeData`|The fee data for the pool|


### setFeeData

Sets the fee data for a given pool


```solidity
function setFeeData(PoolKey calldata poolKey, FeeData memory feeData_) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The pool key|
|`feeData_`|`FeeData`|The fee data for the pool|


### hookParams

Gets the hook params for a given pool


```solidity
function hookParams(PoolId poolId) external view returns (HookParams memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`HookParams`|The hook params for the pool|


### setHookParams

Sets the hook params for a given pool


```solidity
function setHookParams(PoolKey calldata poolKey, HookParams memory hookParams_) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The pool key|
|`hookParams_`|`HookParams`|The hook params for the pool|


### setReferenceSqrtPrice

Sets the reference sqrt price for a given pool


```solidity
function setReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPrice_) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The pool key|
|`referenceSqrtPrice_`|`uint160`|The reference sqrt price for the pool|


### setOptimalFeeSpread

Sets the optimal fee spread for a given pool


```solidity
function setOptimalFeeSpread(PoolKey calldata poolKey, uint24 optimalFeeSpread_) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The pool key|
|`optimalFeeSpread_`|`uint24`|The optimal fee spread for the pool in pips|


### beforeInitialize

Before initialize hook

Checks that the pool is using a dynamic fee


```solidity
function beforeInitialize(address, PoolKey calldata poolKey, uint160) external view onlyByGateway returns (bytes4);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`||
|`poolKey`|`PoolKey`|The pool key|
|`<none>`|`uint160`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes4`|The selector for the before initialize hook|


### beforeSwap

Before swap hook

Calculates the fee for the swap


```solidity
function beforeSwap(address, PoolKey calldata poolKey, SwapParams calldata params, bytes calldata)
    external
    onlyByGateway
    returns (bytes4, BeforeSwapDelta, uint24);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`||
|`poolKey`|`PoolKey`|The pool key|
|`params`|`SwapParams`|The swap parameters|
|`<none>`|`bytes`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes4`|The selector for the before swap hook|
|`<none>`|`BeforeSwapDelta`|The delta for the swap (always 0)|
|`<none>`|`uint24`|The fee for the swap|


### _getStorage

Internal function to get the pool storage


```solidity
function _getStorage(PoolKey calldata poolKey) internal view returns (PoolStorage storage);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The pool key|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`PoolStorage`|The pool storage|


### _getSqrtPriceX96

Internal function to get the sqrt price X96


```solidity
function _getSqrtPriceX96(PoolId poolId) internal view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The sqrt price X96|


## Errors
### MustUseDynamicFee

```solidity
error MustUseDynamicFee();
```

## Structs
### FeeData

```solidity
struct FeeData {
    uint256 previousFee;
    uint160 previousSqrtAmmPrice;
    uint256 blockNumber;
}
```

### HookParams

```solidity
struct HookParams {
    uint256 k;
    uint256 logK;
    uint256 optimalFeeSpread; // optimal fee spread in pips (1e6 = 100%)
    uint160 referenceSqrtPrice;
}
```

### PoolStorage

```solidity
struct PoolStorage {
    FeeData feeData;
    HookParams hookParams;
}
```

