# SlipstreamAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/8f2591d7920c37c7febdcff1c1ab7aa7c00d922f/src/aggregator-hooks/implementations/Slipstream/SlipstreamAggregator.sol)

**Inherits:**
[UniswapV3Aggregator](/src/aggregator-hooks/implementations/UniswapV3/UniswapV3Aggregator.sol/contract.UniswapV3Aggregator.md)

**Title:**
SlipstreamAggregator

Singleton hook aggregating Slipstream-style concentrated liquidity (tickSpacing-keyed factory lookup)


## Functions
### constructor


```solidity
constructor(IPoolManager manager, address slipstreamFactory, address quoter)
    UniswapV3Aggregator(manager, slipstreamFactory, quoter, "SlipstreamAggregator v1.0");
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`manager`|`IPoolManager`|PoolManager|
|`slipstreamFactory`|`address`|Slipstream pool factory (tickSpacing `getPool`)|
|`quoter`|`address`|Aerodrome Slipstream quoter (`IQuoterV2`, not Uni QuoterV2 `fee` tuple)|


### _rawQuote

Aerodrome Slipstream quoters use `int24 tickSpacing` in params (Uni QuoterV2 uses `uint24 fee`).


```solidity
function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    internal
    virtual
    override
    returns (uint256 amountUnspecified);
```

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

### _quoterRoutingHintFromKey

Value stored for QuoterV2 factory routing (`fee` field on QuoterV2 params).

Stored bits match Slipstream quoter `tickSpacing` (same encoding as uint24 narrow cast from `key.tickSpacing`).


```solidity
function _quoterRoutingHintFromKey(PoolKey calldata key) internal pure override returns (uint24);
```

