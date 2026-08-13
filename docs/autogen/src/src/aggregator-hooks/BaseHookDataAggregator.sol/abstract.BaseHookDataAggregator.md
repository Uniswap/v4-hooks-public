# BaseHookDataAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/46ab71e7645df3d64344767b0e4a437258051bb5/src/aggregator-hooks/BaseHookDataAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md)

**Title:**
BaseHookDataAggregator

Variant of {BaseAggregatorHook} for aggregator hooks whose swap behaviour depends on the per-swap
`hookData` (e.g. an encoded order, intent, or signature). It forwards `hookData` into a hookData-aware
`_conductSwap`, so implementations read it straight from calldata — no storage stash, and no change to
the routing `quote` interface.

This contract only overrides settlement so it can thread `hookData` through to a hookData-aware
`_conductSwap`; the shared delta/protocol-fee accounting is reused from `BaseAggregatorHook._innerBeforeSwap`,
so there is no duplicated logic to keep in sync with the base.
Hooks that do not need `hookData` should continue to extend {BaseAggregatorHook} directly so they remain
completely unaffected by this variant.


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, string memory _aggregatorHookVersion)
    BaseAggregatorHook(_manager, _aggregatorHookVersion);
```

### _beforeSwap

Settles via the hookData-aware `_conductSwap`, then delegates the delta/protocol-fee accounting to
the shared `BaseAggregatorHook._innerBeforeSwap`.


```solidity
function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

### _internalSettleWithHookData

Mirror of `BaseAggregatorHook._internalSettle` that forwards `hookData` to `_conductSwap`.


```solidity
function _internalSettleWithHookData(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
    internal
    returns (uint256 amountIn, uint256 amountOut);
```

### _conductSwap

Abstract function for contracts to implement conducting the swap on the aggregated liquidity source

Sealed: hooks on this base implement the hookData-aware overload below. This overload is never reached
because `_beforeSwap` routes through `_internalSettleWithHookData`.


```solidity
function _conductSwap(Currency, Currency, SwapParams calldata, PoolId)
    internal
    override
    returns (uint256, uint256, bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`Currency`||
|`<none>`|`Currency`||
|`<none>`|`SwapParams`||
|`<none>`|`PoolId`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|amountSettle The amount of the currency being settled (swapper's output amount)|
|`<none>`|`uint256`|amountTake The amount of the currency being taken (swapper's input amount)|
|`<none>`|`bool`|hasSettled Whether the swap has been settled inside of the _conductSwap function|


### _conductSwap

Conduct the swap on the aggregated liquidity source using the swap's `hookData`.


```solidity
function _conductSwap(
    Currency settleCurrency,
    Currency takeCurrency,
    SwapParams calldata params,
    PoolId poolId,
    bytes calldata hookData
) internal virtual returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`settleCurrency`|`Currency`|The currency to be settled on the V4 PoolManager (swapper's output currency)|
|`takeCurrency`|`Currency`|The currency to be taken from the V4 PoolManager (swapper's input currency)|
|`params`|`SwapParams`|The swap parameters|
|`poolId`|`PoolId`|The V4 Pool ID|
|`hookData`|`bytes`|The arbitrary hook data forwarded from the swap's beforeSwap call|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountSettle`|`uint256`|The amount of the currency being settled (swapper's output amount)|
|`amountTake`|`uint256`|The amount of the currency being taken (swapper's input amount)|
|`hasSettled`|`bool`|Whether the swap has been settled inside of the _conductSwap function|


### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees

Router-style quoting (no hookData) cannot resolve a per-swap order, so it is unsupported. Use
[quoteWithHookData](/src/aggregator-hooks/BaseHookDataAggregator.sol/abstract.BaseHookDataAggregator.md#quotewithhookdata) instead, supplying the order as hookData.


```solidity
function _rawQuote(bool, int256, PoolId) internal virtual override returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`||
|`<none>`|`int256`||
|`<none>`|`PoolId`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|amountUnspecified The raw unspecified amount before protocol fee adjustment|


### _rawQuoteWithHookData

Returns the raw quote for a swap whose behaviour depends on `hookData`, without protocol fees.

Mirror of [_rawQuote](/src/aggregator-hooks/BaseHookDataAggregator.sol/abstract.BaseHookDataAggregator.md#_rawquote) for hookData-driven hooks. Implementations resolve `hookData` to the
unspecified-side amount; whether this can be `view` depends on the implementation.


```solidity
function _rawQuoteWithHookData(bool zeroToOne, int256 amountSpecified, PoolId poolId, bytes calldata hookData)
    internal
    virtual
    returns (uint256 amountUnspecified);
```

### quoteWithHookData

hookData-aware analogue of {BaseAggregatorHook.quote}: resolves the order/intent in `hookData` and
applies the protocol fee the same way the standard quote does (via the shared `_innerQuote`).


```solidity
function quoteWithHookData(bool zeroToOne, int256 amountSpecified, PoolId poolId, bytes calldata hookData)
    external
    returns (uint256 amountUnspecified);
```

## Errors
### HookDataRequired
Thrown if the hookData-less `_conductSwap` overload is somehow reached. Hooks built on this base
only implement the hookData-aware overload.


```solidity
error HookDataRequired();
```

### QuoteNotSupported

```solidity
error QuoteNotSupported();
```

