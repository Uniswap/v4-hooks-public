# UniswapXAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/56fe7f485c8d67008228c24d14664f55752c8c93/src/aggregator-hooks/implementations/UniswapX/UniswapXAggregator.sol)

**Inherits:**
[BaseHookDataAggregator](/src/aggregator-hooks/BaseHookDataAggregator.sol/abstract.BaseHookDataAggregator.md), IReactorCallback

**Title:**
UniswapXAggregator

Uniswap V4 hook whose "liquidity source" is a single UniswapX order (e.g. a Dutch order)
supplied as swap `hookData`. The hook acts as the UniswapX filler: it calls the Reactor's
`executeWithCallback`, the Reactor pulls the order swapper's input (via Permit2) to this hook
and invokes `reactorCallback`, during which the hook sources the order's required output from
the V4 PoolManager (i.e. from the V4 swapper). The V4 swapper therefore provides the counter-side
liquidity that fills the UniswapX order and, in return, receives the order's input token.

Original Dutch orders are all-or-nothing: the V4 swap amount must exactly match the resolved order
amounts, otherwise the swap reverts. Each swap consumes one order passed fresh via `hookData`, so a
single deployed pool is reusable across many orders for the same token pair.

Routing-style quoting is unsupported: `quote`/`_rawQuote`/`pseudoTotalValueLocked` revert because the
order is only known at swap time (via `hookData`), not when a router calls those view functions.

Protocol fees must remain 0 for pools using this hook. A non-zero protocol fee would skim the
unspecified currency, but an exact order fill leaves no surplus to cover it, causing settlement to fail.


## State Variables
### reactor
The UniswapX reactor this hook fills orders against


```solidity
IReactor public immutable reactor
```


### weth
The canonical wrapped-native token, used to bridge V4 native ETH and order WETH


```solidity
address public immutable weth
```


### registered
Tracks which V4 pools have been registered with this hook


```solidity
mapping(PoolId => bool) public registered
```


### INFLIGHT_SLOT

```solidity
bytes32 private constant INFLIGHT_SLOT = 0x9d6f6b3c2a1e4f8b0c5d7e9a3b1f2c4d6e8a0b2c4d6e8f0a1b3c5d7e9f1a3b5c
```


### RESOLVED_INPUT_SLOT

```solidity
bytes32 private constant RESOLVED_INPUT_SLOT = 0x2f4a6c8e0a2c4e6f8a0c2e4f6a8c0e2f4a6c8e0a2c4e6f8a0c2e4f6a8c0e2f4b
```


### RESOLVED_OUTPUT_SLOT

```solidity
bytes32 private constant RESOLVED_OUTPUT_SLOT = 0x3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5d
```


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, IReactor _reactor, address _weth)
    BaseHookDataAggregator(_manager, "UniswapXAggregator v1.0");
```

### _isEthClass

Returns true if `token` represents native ETH on the order side, accounting for WETH equivalence


```solidity
function _isEthClass(address token) internal view returns (bool);
```

### _matches

Returns true if a V4 currency corresponds to an order-side token, treating ETH and WETH as equivalent


```solidity
function _matches(Currency currency, address orderToken) internal view returns (bool);
```

### _beforeInitialize


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4);
```

### _conductSwap

Conduct the swap on the aggregated liquidity source using the swap's `hookData`.

The swap's hookData is the ABI-encoded UniswapX SignedOrder to fill.


```solidity
function _conductSwap(
    Currency settleCurrency,
    Currency takeCurrency,
    SwapParams calldata params,
    PoolId,
    bytes calldata hookData
) internal override returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`settleCurrency`|`Currency`|The currency to be settled on the V4 PoolManager (swapper's output currency)|
|`takeCurrency`|`Currency`|The currency to be taken from the V4 PoolManager (swapper's input currency)|
|`params`|`SwapParams`|The swap parameters|
|`<none>`|`PoolId`||
|`hookData`|`bytes`|The arbitrary hook data forwarded from the swap's beforeSwap call|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountSettle`|`uint256`|The amount of the currency being settled (swapper's output amount)|
|`amountTake`|`uint256`|The amount of the currency being taken (swapper's input amount)|
|`hasSettled`|`bool`|Whether the swap has been settled inside of the _conductSwap function|


### reactorCallback

Called by the reactor during the execution of an order

Called by the reactor mid-execution. Sources the order's output from the PoolManager (the V4
swapper's input), converting between native ETH and WETH as needed.


```solidity
function reactorCallback(ResolvedOrder[] memory resolvedOrders, bytes memory callbackData) external override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`resolvedOrders`|`ResolvedOrder[]`|Has inputs and outputs|
|`callbackData`|`bytes`|The callbackData specified for an order execution|


### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees

Router-style quoting cannot resolve a per-swap order, so quoting is unsupported.


```solidity
function _rawQuote(bool, int256, PoolId) internal pure override returns (uint256);
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


### pseudoTotalValueLocked

No persistent liquidity exists; TVL is undefined for an order-filling hook.


```solidity
function pseudoTotalValueLocked(PoolId) external pure override returns (uint256, uint256);
```

### _setTransientInflight


```solidity
function _setTransientInflight(bool value) private;
```

### _getTransientInflight


```solidity
function _getTransientInflight() private view returns (bool value);
```

### _setTransientResolved


```solidity
function _setTransientResolved(bytes32 slot, uint256 value) private;
```

### _getTransientResolved


```solidity
function _getTransientResolved(bytes32 slot) private view returns (uint256 value);
```

## Errors
### Reentrancy

```solidity
error Reentrancy();
```

### ProhibitedEntry

```solidity
error ProhibitedEntry();
```

### UnauthorizedCaller

```solidity
error UnauthorizedCaller();
```

### NoOrderData

```solidity
error NoOrderData();
```

### NoOrderOutputs

```solidity
error NoOrderOutputs();
```

### InconsistentOrderOutputs

```solidity
error InconsistentOrderOutputs();
```

### OrderInputMismatch

```solidity
error OrderInputMismatch();
```

### OrderOutputMismatch

```solidity
error OrderOutputMismatch();
```

### OrderAmountMismatch

```solidity
error OrderAmountMismatch();
```

### NativeTransferFailed

```solidity
error NativeTransferFailed();
```

### QuoteNotSupported

```solidity
error QuoteNotSupported();
```

### TVLNotSupported

```solidity
error TVLNotSupported();
```

