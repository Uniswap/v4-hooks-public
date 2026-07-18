# IIndicativeQuote
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/851eb97475fb7ed14074e41059d3e945423bb6be/src/interfaces/IIndicativeQuote.sol)

**Inherits:**
IERC165

**Title:**
IIndicativeQuote

Minimal, non-binding-quote interface for V4 hooks that override the AMM curve but
expose a cheap on-chain price oracle. Designed to sit between the rich `IALFHook`
surface (which carries gas budgets, liveness, attestation) and the universal but
expensive reverting-self-swap quote primitive.

Routers and aggregators (e.g. `ALFMultiplexer`) probe for support via ERC-165 and
call `indicativeQuote` to size split-fills or rank candidates without paying for a
full reverting swap. Implementations SHOULD NOT mutate state. Implementations MAY
return `0` to signal that the pool is currently untradable (e.g. pair retired, no
inventory) — callers treat `0` as "skip this candidate".


## Functions
### indicativeQuote

Non-binding indicative quote for a swap. The actual execution price may differ
(e.g., by a router-applied protocol fee, or by within-block oracle drift).


```solidity
function indicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
    external
    returns (uint256 amountUnspecified);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool key being quoted.|
|`zeroForOne`|`bool`|Swap direction.|
|`amountSpecified`|`int256`|V4 convention: negative for exact input, positive for exact output.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountUnspecified`|`uint256`|For exact-in: expected output amount. For exact-out: required input amount. Always positive (or `0` if no quote is available).|


