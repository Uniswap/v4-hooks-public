# FluidDexT1Aggregator
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/37a7cb81b7d428c0f0c3a3b22f8af4d012f72874/src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md), [IDexCallback](/src/aggregator-hooks/implementations/FluidDexT1/interfaces/IDexCallback.sol/interface.IDexCallback.md)

**Title:**
FluidDexT1Aggregator

Uniswap V4 hook that aggregates liquidity from Fluid DEX T1 pools

Implements Fluid's IDexCallback interface for swap callbacks


## State Variables
### fluidPool
The Fluid DEX T1 pool


```solidity
IFluidDexT1 public immutable fluidPool
```


### fluidLiquidity
Liquidity Layer contract (tokens are transferred here in the callback)


```solidity
address public immutable fluidLiquidity
```


### fluidDexReservesResolver
The Fluid DEX reserves resolver for pool state queries


```solidity
IFluidDexReservesResolver public immutable fluidDexReservesResolver
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


### FLUID_NATIVE_CURRENCY

```solidity
address private constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
```


### INFLIGHT_SLOT

```solidity
bytes32 private constant INFLIGHT_SLOT = 0x60d3e47259b598a408c0f35a2690d6e03fbf8cbc79ab359d5d81f5f451a5750e
```


### INACCURACY_BUFFER

```solidity
uint256 private constant INACCURACY_BUFFER = 20
```


### INACCURACY_SCALE

```solidity
uint256 private constant INACCURACY_SCALE = 1_000_000
```


## Functions
### constructor


```solidity
constructor(
    IPoolManager _manager,
    IFluidDexT1 _fluidDex,
    IFluidDexReservesResolver _fluidDexReservesResolver,
    address _fluidLiquidity
) BaseAggregatorHook(_manager, "FluidDexT1Aggregator v1.0");
```

### dexCallback

dex liquidity callback

Per Fluid docs, tokens should be transferred to the Liquidity Layer.


```solidity
function dexCallback(address token, uint256 amount) external override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`||
|`amount`|`uint256`||


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
function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1);
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


### _swapExactIn


```solidity
function _swapExactIn(
    bool inputIsNative,
    bool fluidSwap0to1,
    uint256 amountIn,
    address recipient,
    Currency takeCurrency
) internal returns (uint256 amountOut);
```

### _swapExactOut


```solidity
function _swapExactOut(
    bool inputIsNative,
    bool outputIsNative,
    bool fluidSwap0to1,
    uint256 amountOut,
    address recipient,
    Currency settleCurrency
) internal returns (uint256 amountIn);
```

### _getBuffer


```solidity
function _getBuffer(uint256 amount) internal pure returns (uint256);
```

### _setTransientInflight


```solidity
function _setTransientInflight(bool value) private;
```

### _getTransientInflight


```solidity
function _getTransientInflight() private view returns (bool value);
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

### TokenNotInPool

```solidity
error TokenNotInPool(address token);
```

### TokensNotInPool

```solidity
error TokensNotInPool(address token0, address token1);
```

