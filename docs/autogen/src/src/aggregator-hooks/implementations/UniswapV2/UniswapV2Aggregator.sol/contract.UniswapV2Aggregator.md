# UniswapV2Aggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/c8009b0f70f3ba0a73cedd796c1cbe2ddce0ddbb/src/aggregator-hooks/implementations/UniswapV2/UniswapV2Aggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md)

**Title:**
UniswapV2Aggregator

Hook that aggregates liquidity from a canonical Uniswap V2 compatible pair resolved via factory.getPair

Fee and tickSpacing on PoolKey do not participate in routing; routing is keyed by currency pair only.


## Constants
### factory

```solidity
address public immutable factory
```


### fee

```solidity
uint256 public immutable fee
```


### FEE_DENOMINATOR

```solidity
uint256 internal constant FEE_DENOMINATOR = 1_000_000
```


## State Variables
### poolIdToExternalPair

```solidity
mapping(PoolId => address) public poolIdToExternalPair
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


## Functions
### constructor


```solidity
constructor(IPoolManager manager, address factory_, uint256 fee_, string memory hookVersion)
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

Prices the swap using reserve math (matching canonical V2 getAmountsOut) and does not account for
fee-on-transfer input tokens. For such tokens the actual output is lower than quoted because the pair
receives less than the nominal input amount. Integrators that pass the quoted value as a router
minimum-output check will see the swap revert on shortfall; no funds are lost.


```solidity
function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    internal
    view
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
    view
    returns (uint256 amountOut);
```

### getAmountIn


```solidity
function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
    internal
    view
    returns (uint256 amountIn);
```

### _swapOnPair

Executes Constant-Product swap on `pair`. Pulls input from PoolManager to `pair` via `take`; pair sends output to PoolManager.


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

