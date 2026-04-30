# SlipstreamAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/adb29379b80d9ef34b021ada72c07961aaf6cc84/src/aggregator-hooks/implementations/Slipstream/SlipstreamAggregator.sol)

**Inherits:**
[UniswapV3Aggregator](/src/aggregator-hooks/implementations/UniswapV3/UniswapV3Aggregator.sol/contract.UniswapV3Aggregator.md)

**Title:**
SlipstreamAggregator

Singleton hook aggregating Slipstream-style concentrated liquidity (tickSpacing-keyed factory lookup)


## Functions
### constructor


```solidity
constructor(IPoolManager manager, address slipstreamFactory)
    UniswapV3Aggregator(manager, slipstreamFactory, "SlipstreamAggregator v1.0");
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`manager`|`IPoolManager`|PoolManager|
|`slipstreamFactory`|`address`|Slipstream pool factory (tickSpacing `getPool`)|


### _resolveExternalPool

Resolve external pool from PoolKey (Uni V3 factory + fee tier)

Slipstream pools are keyed by tickSpacing, not fee tier.


```solidity
function _resolveExternalPool(address token0, address token1, PoolKey calldata key)
    internal
    view
    override
    returns (address pool);
```

