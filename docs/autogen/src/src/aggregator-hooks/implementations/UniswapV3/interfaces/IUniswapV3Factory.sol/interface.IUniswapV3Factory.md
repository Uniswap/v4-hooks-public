# IUniswapV3Factory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/8f2591d7920c37c7febdcff1c1ab7aa7c00d922f/src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3Factory.sol)

**Title:**
IUniswapV3Factory

Minimal Uniswap V3 factory (fee-tier pool lookup)


## Functions
### getPool


```solidity
function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
```

