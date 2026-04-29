# ISlipstreamFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/8f2591d7920c37c7febdcff1c1ab7aa7c00d922f/src/aggregator-hooks/implementations/Slipstream/interfaces/ISlipstreamFactory.sol)

**Title:**
ISlipstreamFactory

Slipstream-style concentrated liquidity pools keyed by tickSpacing (e.g. Aerodrome Slipstream)


## Functions
### getPool


```solidity
function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
```

