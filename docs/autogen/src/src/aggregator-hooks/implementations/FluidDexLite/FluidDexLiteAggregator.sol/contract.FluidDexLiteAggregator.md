# FluidDexLiteAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/b79803a2ede9257f7b93a8c746a6d78104abcfb3/src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md), [IFluidDexLiteCallback](/src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteCallback.sol/interface.IFluidDexLiteCallback.md)

**Title:**
FluidDexLiteAggregator

Uniswap V4 hook that aggregates liquidity from Fluid DEX Lite pools

Implements the IFluidDexLiteCallback interface for swap callbacks


## Constants
### fluidDexLite
The Fluid DEX Lite contract


```solidity
IFluidDexLite public immutable fluidDexLite
```


### fluidDexLiteResolver
The Fluid DEX Lite resolver for pool state queries


```solidity
IFluidDexLiteResolver public immutable fluidDexLiteResolver
```


### salt

```solidity
bytes32 private immutable salt
```


### FLUID_NATIVE_CURRENCY

```solidity
address private constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
```


### INFLIGHT_SLOT

```solidity
bytes32 private constant INFLIGHT_SLOT = 0x60d3e47259b598a408c0f35a2690d6e03fbf8cbc79ab359d5d81f5f451a5750e
```


## State Variables
### dexKey
The key identifying the Fluid DEX Lite pool


```solidity
IFluidDexLite.DexKey public dexKey
```


### localPoolId
The Uniswap V4 pool ID associated with this aggregator


```solidity
PoolId public localPoolId
```


### _isReversed

```solidity
bool private _isReversed
```


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, IFluidDexLite _dexLite, IFluidDexLiteResolver _dexLiteResolver, bytes32 _salt)
    BaseAggregatorHook(_manager, "FluidDexLiteAggregator v1.0");
```

### dexCallback

Called by Fluid DEX Lite to request token transfer from the caller

Must transfer exactly `amount_` of `token_` to msg.sender (the DEX)


```solidity
function dexCallback(address token, uint256 amount, bytes calldata) external override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`||
|`amount`|`uint256`||
|`<none>`|`bytes`||


### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees


```solidity
function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    internal
    override
    returns (uint256 amountUnspecified);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`zeroToOne`|`bool`|Whether the swap is from token0 to token1|
|`amountSpecified`|`int256`|The amount specified (negative for exact-in, positive for exact-out)|
|`poolId`|`PoolId`|The pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountUnspecified`|`uint256`|The raw unspecified amount before protocol fee adjustment|


### pseudoTotalValueLocked


```solidity
function pseudoTotalValueLocked(PoolId poolId) external override returns (uint256 amount0, uint256 amount1);
```

### _beforeInitialize


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4);
```

### _conductSwap

Abstract function for contracts to implement conducting the swap on the aggregated liquidity source

To settle the swap inside of the _conductSwap function, you must follow the 'sync, send,
settle' pattern and set hasSettled to true


```solidity
function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
    internal
    override
    returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`settleCurrency`|`Currency`|The currency to be settled on the V4 PoolManager (swapper's output currency)|
|`takeCurrency`|`Currency`|The currency to be taken from the V4 PoolManager (swapper's input currency)|
|`params`|`SwapParams`|The swap parameters|
|`<none>`|`PoolId`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountSettle`|`uint256`|The amount of the currency being settled (swapper's output amount)|
|`amountTake`|`uint256`|The amount of the currency being taken (swapper's input amount)|
|`hasSettled`|`bool`|Whether the swap has been settled inside of the _conductSwap function|


### _swap


```solidity
function _swap(FluidDexLiteSwapParams memory p, uint256 value) internal returns (uint256 amountUnspecified);
```

### _setTransientInflight


```solidity
function _setTransientInflight(bool value) private;
```

### _getTransientInflight


```solidity
function _getTransientInflight() private view returns (bool value);
```

### isEmpty


```solidity
function isEmpty(IFluidDexLite.DexState memory dexState) private pure returns (bool);
```

## Errors
### UnauthorizedCaller

```solidity
error UnauthorizedCaller();
```

### Reentrancy

```solidity
error Reentrancy();
```

### ProhibitedEntry

```solidity
error ProhibitedEntry();
```

### NativeCurrencyExactOut

```solidity
error NativeCurrencyExactOut();
```

### IncorrectNativeCurrency

```solidity
error IncorrectNativeCurrency();
```

### HookAlreadyInitialized

```solidity
error HookAlreadyInitialized(PoolId poolId);
```

## Structs
### FluidDexLiteSwapParams

```solidity
struct FluidDexLiteSwapParams {
    IFluidDexLite.DexKey dexKey;
    bool swap0To1;
    int256 amountSpecified;
    uint256 amountLimit;
    address payer;
    address recipient;
    bytes extraData;
}
```

