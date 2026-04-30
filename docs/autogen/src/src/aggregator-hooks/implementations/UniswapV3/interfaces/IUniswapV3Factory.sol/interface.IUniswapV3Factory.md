# IUniswapV3Factory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/d636b0c2e723a4f3e275fde691adb8ea9a34eb83/src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3Factory.sol)

**Title:**
IUniswapV3Factory

Minimal Uniswap V3 factory (fee-tier pool lookup)


## Functions
### getPool

Returns the pool address for a pair and fee tier, or `address(0)` if it does not exist


```solidity
function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenA`|`address`|One token of the pair|
|`tokenB`|`address`|The other token of the pair|
|`fee`|`uint24`|Fee tier of the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`pool`|`address`|The pool contract, or zero address if none deployed|


