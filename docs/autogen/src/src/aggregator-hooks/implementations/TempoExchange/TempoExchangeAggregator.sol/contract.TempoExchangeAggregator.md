# TempoExchangeAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/448040189515f587351ce7e06c097f94cdde108c/src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md)

**Title:**
TempoExchangeAggregator

Singleton Uniswap V4 hook that aggregates liquidity from Tempo's enshrined stablecoin DEX

Supports multiple pools and both exact-input and exact-output swaps

Tempo uses uint128 for amounts; this contract handles the conversion from uint256


## State Variables
### tempoExchange
The Tempo stablecoin exchange (precompiled contract)


```solidity
ITempoExchange public immutable tempoExchange
```


### poolIdToTokens
Maps Uniswap V4 pool IDs to their token addresses


```solidity
mapping(PoolId => PoolTokens) public poolIdToTokens
```


### _canonicalPoolByPair
Canonical pool per token pair (key = keccak256(abi.encode(ordered token0, ordered token1)))

Enforces one pool per pair


```solidity
mapping(bytes32 => PoolId) private _canonicalPoolByPair
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
constructor(IPoolManager _manager, ITempoExchange _tempoExchange)
    BaseAggregatorHook(_manager, "TempoExchangeAggregator v1.0");
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_manager`|`IPoolManager`|The Uniswap V4 PoolManager contract|
|`_tempoExchange`|`ITempoExchange`|The Tempo stablecoin exchange address|


### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees


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


### pseudoTotalValueLocked


```solidity
function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1);
```

### _beforeInitialize


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4);
```

### _conductSwap


```solidity
function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
    internal
    override
    returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);
```

### _canonicalPairKey

Returns the canonical storage key for a token pair (ordered by address)


```solidity
function _canonicalPairKey(address token0, address token1) private pure returns (bytes32);
```

### _getBuffer

Returns a buffer to account for per-tick vs per-order rounding in exact-out quotes


```solidity
function _getBuffer(uint256 amount) internal pure returns (uint256);
```

### _safeToUint128

Safely converts uint256 to uint128, reverting on overflow


```solidity
function _safeToUint128(uint256 value) internal pure returns (uint128);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`value`|`uint256`|The uint256 value to convert|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint128`|The uint128 value|


## Errors
### AmountExceedsUint128

```solidity
error AmountExceedsUint128();
```

### TokensNotSupported

```solidity
error TokensNotSupported(address token0, address token1);
```

### ExchangeDoesNotSupportPair

```solidity
error ExchangeDoesNotSupportPair(address token0, address token1);
```

### PairAlreadyHasCanonicalPool

```solidity
error PairAlreadyHasCanonicalPool(PoolId existingPoolId, address token0, address token1);
```

## Structs
### PoolTokens
Token pair info for each registered pool


```solidity
struct PoolTokens {
    address token0;
    address token1;
}
```

