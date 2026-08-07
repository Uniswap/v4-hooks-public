# UniswapXAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/1760682c09b9c83ece9c9ac2d65ba19a027d9e37/src/aggregator-hooks/implementations/UniswapX/UniswapXAggregator.sol)

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

Original Dutch orders are all-or-nothing: the whole order fills or nothing does. The V4 swap amount
only needs to cover the order, not match it exactly: an exact-in swap may specify more input than the
order's resolved output requires, and an exact-out swap may request less than the order's input
supplies — any surplus is forwarded to the protocol's token jar (or left in this hook if no jar is
configured). The swap reverts only when the order's required output exceeds the specified input
(exact-in) or the order supplies less than the requested output (exact-out). Each swap consumes one
order passed fresh via `hookData`, so a
single deployed pool is reusable across many orders for the same token pair.

Stateless across pools: this hook holds no per-pool configuration (the order fully determines the
token pair and amounts at swap time), so one deployed hook instance can be the `hooks` address for
any number of V4 pools — no per-pool factory or deployment is needed. Simply mine one hook address
(see `AggregatorHookMiner`/`HookMiner`), deploy it once, then call `PoolManager.initialize` directly
for each pool that should use it.

Routing-style quoting (no hookData) is unsupported: `quote`/`_rawQuote`/`pseudoTotalValueLocked` revert
because the order is only known at swap time. Use `quoteWithHookData`, which resolves the supplied order
via UniswapX's OrderQuoter (note: not a view — see `_rawQuoteWithHookData`).

This hook opts out of protocol-fee classification: `protocolFeeFlags` returns 0, so pools using it
are not subject to a protocol fee.


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


### orderQuoter
Lens used to resolve an order (Dutch decay applied) into its current input/output amounts


```solidity
OrderQuoter public immutable orderQuoter
```


### INFLIGHT_SLOT

```solidity
bytes32 private constant INFLIGHT_SLOT = 0x1176e989128e5c0647e83e232d1bddeb5fda2c2633b1403aa0480ddc5744db90
```


### RESOLVED_INPUT_SLOT

```solidity
bytes32 private constant RESOLVED_INPUT_SLOT = 0xb118917dbd5ff3662ea80ab603cec995cb9a6b1dc1ad61eda6f03b34bbbfb660
```


### RESOLVED_OUTPUT_SLOT

```solidity
bytes32 private constant RESOLVED_OUTPUT_SLOT = 0xc5b5e49dc52e02802787e6d9f0f9a1f57867b6b3c54b85bf17b6914c521972d2
```


### MAX_INT128
Upper bound for order amounts. The V4 swap delta is formed via `int128(uint128(amount))` in the
base `_processAmounts`, so any amount above `int128.max` would silently sign-flip/truncate the
delta. Both the order input and (summed) output are validated against this before being used.


```solidity
uint256 private constant MAX_INT128 = uint256(uint128(type(int128).max))
```


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, IReactor _reactor, address _weth)
    BaseHookDataAggregator(_manager, "UniswapXAggregator v1.0");
```

### protocolFeeFlags


```solidity
function protocolFeeFlags() external pure override returns (uint256);
```

### _rawQuoteWithHookData

Returns the raw quote for a swap whose behaviour depends on `hookData`, without protocol fees.

Resolves the order in `hookData` (Dutch decay applied) via the OrderQuoter and returns the amount on
the side opposite `amountSpecified`. WARNING: the order fully determines both amounts, so `zeroToOne`
and `poolId` are ignored — quoting the wrong pool or direction still returns an answer; callers must
pass the pool/direction they intend to swap. NOTE: like UniswapX's OrderQuoter this is NOT a view —
it calls the reactor (pulling the maker's input via Permit2 before rolling back), so it requires a
funded, approved, validly-signed order and cannot be `staticcall`-ed.


```solidity
function _rawQuoteWithHookData(bool, int256 amountSpecified, PoolId, bytes calldata hookData)
    internal
    override
    returns (uint256 amountUnspecified);
```

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


### pseudoTotalValueLocked

No persistent liquidity exists; TVL is undefined for an order-filling hook.


```solidity
function pseudoTotalValueLocked(PoolId) external pure override returns (uint256, uint256);
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
function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
    internal
    override
    returns (bytes4);
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

## Events
### SurplusCollected
Emitted when the surplus between the V4 swap amount and the resolved order amount is
forwarded to the token jar


```solidity
event SurplusCollected(address indexed tokenJar, Currency indexed currency, uint256 amount);
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

### UnexpectedOrderCount

```solidity
error UnexpectedOrderCount();
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

### OrderInputOverflow

```solidity
error OrderInputOverflow();
```

### OrderOutputOverflow

```solidity
error OrderOutputOverflow();
```

### NativeTransferFailed

```solidity
error NativeTransferFailed();
```

### TVLNotSupported

```solidity
error TVLNotSupported();
```

