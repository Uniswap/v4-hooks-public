# BaseHookDataAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/56fe7f485c8d67008228c24d14664f55752c8c93/src/aggregator-hooks/BaseHookDataAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md)

**Title:**
BaseHookDataAggregator

Variant of {BaseAggregatorHook} for aggregator hooks whose swap behaviour depends on the per-swap
`hookData` (e.g. an encoded order, intent, or signature). It forwards `hookData` into a hookData-aware
`_conductSwap`, so implementations read it straight from calldata — no storage stash, and no change to
the routing `quote` interface.

This contract deliberately re-implements `_beforeSwap` / `_internalSettle` from {BaseAggregatorHook} so it
can thread `hookData` through to `_conductSwap`. The delta/protocol-fee accounting below is a verbatim
mirror of `BaseAggregatorHook._beforeSwap`; if that logic ever changes, update it here too.
Hooks that do not need `hookData` should continue to extend {BaseAggregatorHook} directly so they remain
completely unaffected by this variant.


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, string memory _aggregatorHookVersion)
    BaseAggregatorHook(_manager, _aggregatorHookVersion);
```

### _beforeSwap

Mirrors `BaseAggregatorHook._beforeSwap` exactly, except it forwards `hookData` to `_conductSwap`.


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


## Errors
### HookDataRequired
Thrown if the hookData-less `_conductSwap` overload is somehow reached. Hooks built on this base
only implement the hookData-aware overload.


```solidity
error HookDataRequired();
```

