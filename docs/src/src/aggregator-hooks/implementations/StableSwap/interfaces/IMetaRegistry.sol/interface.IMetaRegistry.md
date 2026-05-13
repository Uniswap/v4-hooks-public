# IMetaRegistry
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/2be48d7f4fbdc30390a03b6da2febe82639b089c/src/aggregator-hooks/implementations/StableSwap/interfaces/IMetaRegistry.sol)

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


### is_registered

Check if a pool is registered in Curve's registry

Reverts if the pool is not in any registry


```solidity
function is_registered(address _pool, uint256 _handler_id) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Address of the pool|
|`_handler_id`|`uint256`|ID of the RegistryHandler (0 for default)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if the pool is registered|


