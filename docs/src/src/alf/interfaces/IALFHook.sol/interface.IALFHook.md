# IALFHook
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0c68c6912ec9b3df692fd62740997db52f245b7d/src/alf/interfaces/IALFHook.sol)

**Inherits:**
IERC165

**Title:**
IALFHook

**Author:**
Uniswap Labs

Standard interface implemented by ALF hooks on top of the v4 hook interface.

Provides a uniform way for the router and multiplexer to query indicative quotes
and hook metadata. Hooks expose their own capabilities directly rather than
relying on a separate registry contract.

**Note:**
security-contact: security@uniswap.org


## Functions
### getIndicativeQuote

Get an indicative quote for routing purposes.

MUST be a view function. Callers invoke via staticcall.

MUST NOT revert under normal conditions. If the quoter cannot
price the requested swap, it SHOULD return 0.

The returned value is non-binding. The actual execution price
is determined by the hook's beforeSwap implementation.


```solidity
function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
    external
    view
    returns (uint256 outputAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool key for this quoter's pool.|
|`zeroForOne`|`bool`|The swap direction.|
|`amountSpecified`|`int256`|The swap amount. Negative = exact input.|
|`hookData`|`bytes`|ABI-encoded ALFHookData struct, or empty bytes.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`outputAmount`|`uint256`|The indicative number of output tokens. For exact input swaps, this is the expected output. For exact output swaps, this is the required input.|


### isLive

Whether this hook is currently live and accepting swaps.

Hooks SHOULD return true if the current curve is not stale.

Consumers SHOULD validate against observed behavior.


```solidity
function isLive() external view returns (bool);
```

### maxGas

The declared maximum gas for getIndicativeQuote execution.

Callers use this to set gas limits on staticcall invocations.

Hooks that exceed their declared maxGas will have their
getIndicativeQuote calls fail, resulting in router deprioritization.


```solidity
function maxGas() external view returns (uint32);
```

### getReserves

Total reserves managed by the hook (true TVL).

Should include ALL assets under management: ERC-20 balances, ERC-6909 claims,
vault deposits, rehypothecated assets, etc. Returns (0, 0) for hooks that do
not manage off-pool reserves.


```solidity
function getReserves(PoolKey calldata key) external view returns (uint256 token0, uint256 token1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool key for the specific pool.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`token0`|`uint256`|Total amount of token0 reserves.|
|`token1`|`uint256`|Total amount of token1 reserves.|


### getEffectiveLiquidity

Assets available for immediate swapping.

Returns liquidity that can be accessed right now for trading. Always <= getReserves().
May differ from getReserves() if some liquidity is not available for deployment (e.g., from a vault with too much utilization).
Returns (0, 0) for hooks that do not manage off-pool reserves.


```solidity
function getEffectiveLiquidity(PoolKey calldata key) external view returns (uint256 token0, uint256 token1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool key for the specific pool.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`token0`|`uint256`|Immediately swappable token0 liquidity.|
|`token1`|`uint256`|Immediately swappable token1 liquidity.|


### swapToPrice

Simulate a swap up to a target price, returning both input consumed and output received.

Used by the multiplexer and router for split fill planning. The swap terminates
when the target price is reached or the specified amount is exhausted, whichever
comes first. Returns (0, 0) for hooks that do not support price-bounded simulation.


```solidity
function swapToPrice(
    PoolKey calldata key,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata hookData
) external view returns (uint256 amountIn, uint256 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool key for this quoter's pool.|
|`zeroForOne`|`bool`|The swap direction.|
|`amountSpecified`|`int256`|The swap amount. Negative = exact input.|
|`sqrtPriceLimitX96`|`uint160`|The target price (Q64.96). Swap stops when this price is reached.|
|`hookData`|`bytes`|ABI-encoded ALFHookData struct, or empty bytes.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Total input consumed (including fees).|
|`amountOut`|`uint256`|Total output received.|


