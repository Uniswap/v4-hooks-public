# ISlipstreamFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/d636b0c2e723a4f3e275fde691adb8ea9a34eb83/src/aggregator-hooks/implementations/Slipstream/interfaces/ISlipstreamFactory.sol)

**Title:**
ISlipstreamFactory

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


