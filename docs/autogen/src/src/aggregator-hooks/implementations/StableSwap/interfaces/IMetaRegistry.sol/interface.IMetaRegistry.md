# IMetaRegistry
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/17d7d5811380e775c83dd0663f30fb95c53d02b9/src/aggregator-hooks/implementations/StableSwap/interfaces/IMetaRegistry.sol)

**Title:**
IMetaRegistry

Minimal interface for Curve's MetaRegistry to check meta pool status

See https://docs.curve.finance/developer/integration/meta-registry#is_meta


## Functions
### is_meta

Check if a pool is a metapool


```solidity
function is_meta(address _pool, uint256 _handler_id) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Address of the pool|
|`_handler_id`|`uint256`|ID of the RegistryHandler|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if the pool is a metapool|


