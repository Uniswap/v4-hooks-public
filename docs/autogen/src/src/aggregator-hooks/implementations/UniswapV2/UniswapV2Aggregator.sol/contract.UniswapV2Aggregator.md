# UniswapV2Aggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/416380a49deeb0994c53d8587637126ada687be9/src/aggregator-hooks/implementations/UniswapV2/UniswapV2Aggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md)

**Title:**
UniswapV2Aggregator

Hook that aggregates liquidity from a canonical Uniswap V2 compatible pair resolved via factory.getPair

Fee and tickSpacing on PoolKey do not participate in routing; routing is keyed by currency pair only.


## State Variables
### factory

```solidity
address public immutable factory
```


### FEE

```solidity
uint256 internal constant FEE = 3
```


### FEE_DENOMINATOR

```solidity
uint256 internal constant FEE_DENOMINATOR = 1000
```


### poolIdToExternalPair

```solidity
mapping(PoolId => address) public poolIdToExternalPair
```


### _canonicalPoolKeyByAddress

```solidity
mapping(address => PoolKey) private _canonicalPoolKeyByAddress
```


### _currentPayer
Payer for the in-flight exact-out flash swap. Captured by `_beforeSwap` (from `hookData` if a payer was
encoded, otherwise from the `sender` param) and consumed inside `uniswapV2Call` to pull the input token
directly into the V2 pair. Transient — implicitly cleared at end of transaction and also explicitly
cleared once `super._beforeSwap` returns.


```solidity
address private transient _currentPayer
```


## Functions
### constructor


```solidity
constructor(IPoolManager manager, address factory_, string memory hookVersion)
    BaseAggregatorHook(manager, hookVersion);
```

### pseudoTotalValueLocked


```solidity
function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1);
```

### _resolveExternalPool


```solidity
function _resolveExternalPool(address token0, address token1) internal view returns (address pool);
```

### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees


```solidity
function _rawQuote(bool zeroForOne, int256 amountSpecified, PoolId poolId)
    internal
    view
    override
    returns (uint256 amountUnspecified);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`zeroForOne`|`bool`||
|`amountSpecified`|`int256`|The amount specified (negative for exact-in, positive for exact-out)|
|`poolId`|`PoolId`|The pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountUnspecified`|`uint256`|The raw unspecified amount before protocol fee adjustment|


### _beforeInitialize


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4);
```

### _beforeSwap

Captures the input-token payer for the exact-out flash-swap path, then chains to the base implementation.
Convention: routers pass `abi.encode(address payer)` as `hookData`; if `hookData` is empty (or shorter than
one word), we fall back to the `sender` of `beforeSwap` (i.e. the caller of `pm.swap`). The payer must have
approved this hook for the input token — see `uniswapV2Call` for the safeTransferFrom that consumes it.


```solidity
function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

### _conductSwap

Abstract function for contracts to implement conducting the swap on the aggregated liquidity source

To settle the swap inside of the _conductSwap function, you must follow the 'sync, send,
settle' pattern and set hasSettled to true


```solidity
function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
    internal
    virtual
    override
    returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`settleCurrency`|`Currency`|The currency to be settled on the V4 PoolManager (swapper's output currency)|
|`takeCurrency`|`Currency`|The currency to be taken from the V4 PoolManager (swapper's input currency)|
|`params`|`SwapParams`|The swap parameters|
|`poolId`|`PoolId`|The V4 Pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountSettle`|`uint256`|The amount of the currency being settled (swapper's output amount)|
|`amountTake`|`uint256`|The amount of the currency being taken (swapper's input amount)|
|`hasSettled`|`bool`|Whether the swap has been settled inside of the _conductSwap function|


### getAmountOut


```solidity
function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
    internal
    pure
    returns (uint256 amountOut);
```

### getAmountIn


```solidity
function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
    internal
    pure
    returns (uint256 amountIn);
```

### _swapOnPair

Executes exact-in Constant-Product swap on `pair`. Pulls input from PoolManager to `pair` via `take`; pair sends output to PoolManager.


```solidity
function _swapOnPair(address pairAddr, Currency takeCurrency, Currency settleCurrency, SwapParams calldata params)
    private
    returns (uint256 amountTakeUsed, uint256 amountSettle);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountTakeUsed`|`uint256`|Input amount taken from PoolManager for the pair.|
|`amountSettle`|`uint256`|Output amount sent by the pair to PoolManager (must match `settle` after `sync`).|


### _flashSwapExactOut

Executes exact-out Constant-Product swap on `pair` via V2 flash-swap inversion: pair sends output to this
hook optimistically, then `uniswapV2Call` settles the output into PoolManager and pulls the input from the
payer (cached in `_currentPayer` by `_beforeSwap`) directly into the pair, bypassing PoolManager entirely.
Required for lazy-settlement exact-out routing where PoolManager holds zero of the input token at hook-fire
time. The returned `amountTakeUsed` is zero so the base class' BeforeSwapDelta requires no input through PM.


```solidity
function _flashSwapExactOut(
    address pairAddr,
    Currency takeCurrency,
    Currency settleCurrency,
    SwapParams calldata params
) private returns (uint256 amountTakeUsed, uint256 amountSettle);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountTakeUsed`|`uint256`|Always 0 for exact-out: input is pulled from `payer` via `safeTransferFrom`, not from PM.|
|`amountSettle`|`uint256`|Output amount delivered to PoolManager (must equal `params.amountSpecified`).|


### uniswapV2Call

Uniswap V2 flash-swap callback. Invoked by the pair after it has optimistically transferred the output
token to this hook in an exact-out flow. Settles the output into PoolManager, then repays the pair by
pulling the input token directly from the payer's wallet via `safeTransferFrom` — PoolManager is never
touched for the input leg.

The payer (encoded in `cb.payer`, captured from `beforeSwap`'s `hookData` or `sender`) MUST have approved
this hook contract for the input token. Input repayment bypasses PoolManager because PM may hold zero of
the input token at hook-fire time under lazy-settlement routing (e.g. Universal Router).

Auth checks are load-bearing: only the encoded pair may invoke this, and only when this hook initiated the
flash swap (sender == self). Otherwise an attacker could drain the payer via `safeTransferFrom`.


```solidity
function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
```

## Errors
### NativeCurrencyNotSupported

```solidity
error NativeCurrencyNotSupported();
```

### ExternalPoolNotFound

```solidity
error ExternalPoolNotFound();
```

### ExternalPoolTokenMismatch

```solidity
error ExternalPoolTokenMismatch();
```

### Reentrancy

```solidity
error Reentrancy();
```

### UnexpectedSwapOutputDelta

```solidity
error UnexpectedSwapOutputDelta();
```

### AmountInZero

```solidity
error AmountInZero();
```

### AmountOutZero

```solidity
error AmountOutZero();
```

### InsufficientLiquidity

```solidity
error InsufficientLiquidity();
```

### PairAlreadyHasCanonicalPool

```solidity
error PairAlreadyHasCanonicalPool(PoolId existingPoolId);
```

### CallerNotV2Pair

```solidity
error CallerNotV2Pair();
```

### SenderNotSelf

```solidity
error SenderNotSelf();
```

## Structs
### FlashCallbackData

```solidity
struct FlashCallbackData {
    address pairAddr;
    Currency takeCurrency;
    Currency settleCurrency;
    uint256 amountIn;
    address payer;
}
```

