# IQuoterV2
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/d636b0c2e723a4f3e275fde691adb8ea9a34eb83/src/aggregator-hooks/implementations/Slipstream/interfaces/IQuoterV2.sol)

**Title:**
IQuoterV2

Aerodrome Slipstream Base quoter ABI (`int24 tickSpacing` — Uni QuoterV2 uses `uint24 fee`).


## Functions
### quoteExactInputSingle

Simulates a single-hop exact-input swap and returns the output amount without state changes


```solidity
function quoteExactInputSingle(QuoteExactInputSingleParams memory params) external returns (uint256 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`QuoteExactInputSingleParams`|Single-hop exact-input quote parameters|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountOut`|`uint256`|Amount of `tokenOut` that would be received for `params.amountIn`|


### quoteExactOutputSingle

Simulates a single-hop exact-output swap and returns the required input without state changes


```solidity
function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params) external returns (uint256 amountIn);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`QuoteExactOutputSingleParams`|Single-hop exact-output quote parameters|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of `tokenIn` required to receive `params.amountOut`|


## Structs
### QuoteExactInputSingleParams

```solidity
struct QuoteExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    int24 tickSpacing;
    uint160 sqrtPriceLimitX96;
}
```

### QuoteExactOutputSingleParams

```solidity
struct QuoteExactOutputSingleParams {
    address tokenIn;
    address tokenOut;
    uint256 amountOut;
    int24 tickSpacing;
    uint160 sqrtPriceLimitX96;
}
```

