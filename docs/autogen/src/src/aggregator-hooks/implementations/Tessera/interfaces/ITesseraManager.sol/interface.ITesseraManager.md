# ITesseraManager
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/03c6c317e620e2eb32675653ad26bf7faacc5605/src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraManager.sol)

**Title:**
ITesseraManager

Interface for the Tessera pool registry

Lives at 0x31e99E05fee3DCE580af777C3fD63eE1B3B40c17 on Base and BSC.


## Functions
### getTesseraPool

Returns whether a direct Tessera pool exists for the given pair, and its address if so.


```solidity
function getTesseraPool(address tokenA, address tokenB) external view returns (bool exists, address pool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenA`|`address`|One side of the pair (any ordering).|
|`tokenB`|`address`|The other side of the pair.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`exists`|`bool`|True if a direct pool is registered for the pair (not a multi-hop route).|
|`pool`|`address`|The underlying Tessera pool address, or `address(0)` if `exists` is false.|


### baseRoutingAsset

The asset Tessera uses as the routing hop for indirect pairs (typically USDC).

Our hook rejects multi-hop pairs; this is only useful for diagnostics.


```solidity
function baseRoutingAsset() external view returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The base routing asset address used by Tessera for two-hop routes.|


### isActive

Global on/off switch for the manager.


```solidity
function isActive() external view returns (bool);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if the Tessera system is currently accepting trades.|


### tesseraPoolsCount

Number of pools currently registered with the manager.


```solidity
function tesseraPoolsCount() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The count of registered Tessera pools.|


