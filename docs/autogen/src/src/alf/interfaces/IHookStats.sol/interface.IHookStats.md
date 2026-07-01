# IHookStats
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/interfaces/IHookStats.sol)

**Inherits:**
IERC165

**Title:**
IHookStats

**Author:**
Uniswap Labs

Reserves-and-liquidity metadata surface for hooks that custody off-pool assets. Lets
routers and aggregators (e.g. the ALFMultiplexer) read a hook's total value under
management and its immediately-deliverable liquidity to size fills and bound slippage.

Advertised and discovered via ERC-165 (`supportsInterface`); callers query it through
`staticcall`. It is a read-only signal, not a binding commitment: the amounts may drift
between the query and execution so consumers MUST treat them as non-binding and enforce
their own execution-time bounds. Hooks that hold no off-pool reserves (e.g. native LP
quoters) return `(0, 0)` from both functions. The pairing carries one invariant:
`getEffectiveLiquidity(key) <= getReserves(key)` on each side.

**Note:**
security-contact: security@uniswap.org


## Functions
### getReserves

Total reserves managed by the hook (true TVL).

Should include all assets under management: ERC-20 balances, ERC-6909 claims,
vault deposits, rehypothecated assets, etc. Returns (0, 0) for hooks that do
not manage off-pool reserves. This is the gross economic stake and MAY exceed what is
immediately withdrawable (see [getEffectiveLiquidity](/src/alf/interfaces/IHookStats.sol/interface.IHookStats.md#geteffectiveliquidity)).


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
|`token0`|`uint256`|Total amount of token0 reserves, in token0's native decimals.|
|`token1`|`uint256`|Total amount of token1 reserves, in token1's native decimals.|


### getEffectiveLiquidity

Assets available for immediate swapping.

Returns liquidity that can be accessed right now for trading. Always <= getReserves().
May differ from getReserves() if some liquidity is not available for deployment (e.g., from a vault with too much utilization).
Returns (0, 0) for hooks that do not manage off-pool reserves.
Implementations SHOULD report fee-net, immediately-deliverable reserves: consumers (such as
the ALFMultiplexer's reserve-bounded strict-tolerance baseline) treat the returned value as
the deliverable output cap, a bound that is only sound when reserves are net of the fee a swap
pays. An over-reported (gross) value weakens those consumers' deliverability bounds, which is
part of the trusted-targets assumption such consumers make.


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
|`token0`|`uint256`|Immediately swappable token0 liquidity, in token0's native decimals.|
|`token1`|`uint256`|Immediately swappable token1 liquidity, in token1's native decimals.|


