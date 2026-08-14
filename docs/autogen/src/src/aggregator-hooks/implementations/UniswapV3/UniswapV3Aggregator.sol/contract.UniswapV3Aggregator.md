# UniswapV3Aggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/5487b2c1a8e5d06a78754ce93a8634b8dd91d659/src/aggregator-hooks/implementations/UniswapV3/UniswapV3Aggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md), [IUniswapV3SwapCallback](/src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3SwapCallback.sol/interface.IUniswapV3SwapCallback.md)

**Title:**
UniswapV3Aggregator

Singleton hook aggregating concentrated liquidity from Uniswap V3 compatible pools (fee-tier factory lookup)


## State Variables
### factory
Uniswap V3 factory used for default pool resolution (fee tier from PoolKey.fee)


```solidity
address public immutable factory
```


### poolIdToExternalPool
External CL pool per registered Uniswap V4 pool


```solidity
mapping(PoolId => address) public poolIdToExternalPool
```


### _canonicalPoolKeyByAddress

```solidity
mapping(address => PoolKey) private _canonicalPoolKeyByAddress
```


### _initializedPools
PoolKeys of all pools initialized with this hook, in initialization order


```solidity
PoolKey[] internal _initializedPools
```


### MIN_SQRT_RATIO_ADJ

```solidity
uint160 internal constant MIN_SQRT_RATIO_ADJ = TickMath.MIN_SQRT_PRICE + 1
```


### MAX_SQRT_RATIO_ADJ

```solidity
uint160 internal constant MAX_SQRT_RATIO_ADJ = TickMath.MAX_SQRT_PRICE - 1
```


### TRANSIENT_EXPECTED_POOL

```solidity
bytes32 private constant TRANSIENT_EXPECTED_POOL =
    0x6eabd122407eeebc08f840712abe83f91a845b97d0fe375ce6644f6d5a2cb3a2
```


### TRANSIENT_SWAP_INPUT_PAID

```solidity
bytes32 private constant TRANSIENT_SWAP_INPUT_PAID =
    0x582465caaa3a5bc4afb238d59b626acb3a16194fc90d0d5ec69b636bbd73057a
```


## Functions
### constructor


```solidity
constructor(IPoolManager manager, address factory_, string memory hookVersion)
    BaseAggregatorHook(manager, hookVersion);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`manager`|`IPoolManager`|PoolManager|
|`factory_`|`address`|Uniswap V3 factory (fee-tier `getPool`)|
|`hookVersion`|`string`|Display version string|


### uniswapV3SwapCallback

Called to `msg.sender` after executing a swap on the pool


```solidity
function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount0Delta`|`int256`|Owed amount of token0: pay pool if positive, receive from pool if negative|
|`amount1Delta`|`int256`|Owed amount of token1: pay pool if positive, receive from pool if negative|
|`data`|`bytes`|Arbitrary data forwarded from the `swap` call, e.g. payer routing|


### _processCallback


```solidity
function _processCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal;
```

### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees


```solidity
function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    internal
    virtual
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


### _quoteViaPoolCallRevertData

Low-level `call`: same-contract callback reverts do not surface through try/catch on a direct `swap` call.


```solidity
function _quoteViaPoolCallRevertData(address poolAddr, bool zeroToOne, int256 v3AmountSpecified, PoolId poolId)
    private
    returns (bytes memory revertData);
```

### _unspecifiedSideFromQuoteDeltas


```solidity
function _unspecifiedSideFromQuoteDeltas(bool zeroToOne, bool exactInput, int256 amount0Delta, int256 amount1Delta)
    private
    pure
    returns (uint256 amt);
```

### _decodeQuoteRevert


```solidity
function _decodeQuoteRevert(bytes memory reason) private pure returns (int256 amount0Delta, int256 amount1Delta);
```

### pseudoTotalValueLocked


```solidity
function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1);
```

### _resolveExternalPool

Resolve external pool from PoolKey (Uni V3 factory + fee tier)


```solidity
function _resolveExternalPool(address token0, address token1, PoolKey calldata key)
    internal
    view
    virtual
    returns (address pool);
```

### initializedLength

Number of pools initialized with this hook


```solidity
function initializedLength() external view returns (uint256);
```

### initialized

Returns the PoolKey of an initialized pool


```solidity
function initialized(uint256 index) external view returns (PoolKey memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`index`|`uint256`|The pool index (in initialization order)|


### _beforeInitialize


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4);
```

### _conductSwap

Abstract function for contracts to implement conducting the swap on the aggregated liquidity source

To settle the swap inside of the _conductSwap function, you must follow the 'sync, send,
settle' pattern and set hasSettled to true


```solidity
function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
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
|`poolId`|`PoolId`|The V4 Pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountSettle`|`uint256`|The amount of the currency being settled (swapper's output amount)|
|`amountTake`|`uint256`|The amount of the currency being taken (swapper's input amount)|
|`hasSettled`|`bool`|Whether the swap has been settled inside of the _conductSwap function|


### _setTransientExpectedPool


```solidity
function _setTransientExpectedPool(address pool) private;
```

### _transientExpectedPool


```solidity
function _transientExpectedPool() private view returns (address);
```

### _setTransientSwapInputPaid


```solidity
function _setTransientSwapInputPaid(uint256 amt) private;
```

### _getTransientSwapInputPaid


```solidity
function _getTransientSwapInputPaid() private view returns (uint256 amt);
```

### receive


```solidity
receive() external payable override;
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

### ExternalPoolMismatch

```solidity
error ExternalPoolMismatch();
```

### UnauthorizedCallback

```solidity
error UnauthorizedCallback();
```

### CallbackOutsideActiveSwap

```solidity
error CallbackOutsideActiveSwap();
```

### Reentrancy

```solidity
error Reentrancy();
```

### UnexpectedSwapOutputDelta

```solidity
error UnexpectedSwapOutputDelta();
```

### PairAlreadyHasCanonicalPool

```solidity
error PairAlreadyHasCanonicalPool(PoolId existingPoolId);
```

### QuoteRevert

```solidity
error QuoteRevert(int256 amount0Delta, int256 amount1Delta);
```

### UnexpectedQuoteBehavior

```solidity
error UnexpectedQuoteBehavior();
```

