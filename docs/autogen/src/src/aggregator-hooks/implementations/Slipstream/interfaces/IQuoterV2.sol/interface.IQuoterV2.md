# IQuoterV2
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/8f2591d7920c37c7febdcff1c1ab7aa7c00d922f/src/aggregator-hooks/implementations/Slipstream/interfaces/IQuoterV2.sol)

**Title:**
IQuoterV2

Aerodrome Slipstream Base quoter ABI (`int24 tickSpacing` — Uni QuoterV2 uses `uint24 fee`).


## Functions
### quoteExactInputSingle


```solidity
function quoteExactInputSingle(QuoteExactInputSingleParams memory params) external returns (uint256 amountOut);
```

### quoteExactOutputSingle


```solidity
function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params) external returns (uint256 amountIn);
```

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

