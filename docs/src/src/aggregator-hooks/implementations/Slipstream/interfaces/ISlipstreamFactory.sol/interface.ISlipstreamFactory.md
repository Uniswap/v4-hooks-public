# ISlipstreamFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/2be48d7f4fbdc30390a03b6da2febe82639b089c/src/aggregator-hooks/implementations/Slipstream/interfaces/ISlipstreamFactory.sol)

Slipstream-style concentrated liquidity pools keyed by tickSpacing (e.g. Aerodrome Slipstream)


## Functions
### getPool

Returns the pool address for a pair and tick spacing, or `address(0)` if it does not exist


```solidity
function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenA`|`address`|One token of the pair|
|`tokenB`|`address`|The other token of the pair|
|`tickSpacing`|`int24`|Tick spacing of the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`pool`|`address`|The pool contract, or zero address if none deployed|


