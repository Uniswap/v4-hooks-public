# ICurveStableSwapFactoryNG
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/17d7d5811380e775c83dd0663f30fb95c53d02b9/src/aggregator-hooks/implementations/StableSwapNG/interfaces/ICurveStableSwapFactoryNG.sol)

**Title:**
ICurveStableSwapFactoryNG

Interface for Curve StableSwap NG Factory

Based on the Vyper implementation at https://github.com/curvefi/stableswap-ng


## Functions
### deploy_plain_pool

Deploy a new plain pool


```solidity
function deploy_plain_pool(
    string memory _name,
    string memory _symbol,
    address[] memory _coins,
    uint256 _A,
    uint256 _fee,
    uint256 _offpeg_fee_multiplier,
    uint256 _ma_exp_time,
    uint256 _implementation_idx,
    uint8[] memory _asset_types,
    bytes4[] memory _method_ids,
    address[] memory _oracles
) external returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_name`|`string`|Name of the new plain pool|
|`_symbol`|`string`|Symbol for the new plain pool|
|`_coins`|`address[]`|List of addresses of the coins being used in the pool|
|`_A`|`uint256`|Amplification coefficient (suggested: 5-10 for algo stables, 100 for non-redeemable, 200-400 for redeemable)|
|`_fee`|`uint256`|Trade fee with 1e10 precision (max 1% = 100000000)|
|`_offpeg_fee_multiplier`|`uint256`|Off-peg fee multiplier|
|`_ma_exp_time`|`uint256`|Moving average time window (e.g., 866 for 10 min EMA)|
|`_implementation_idx`|`uint256`|Index of the implementation to use|
|`_asset_types`|`uint8[]`|Asset types (0=Standard, 1=Oracle, 2=Rebasing, 3=ERC4626)|
|`_method_ids`|`bytes4[]`|Method IDs for rate oracles (use bytes4(0) for standard tokens)|
|`_oracles`|`address[]`|Oracle addresses (use address(0) for standard tokens)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The address of the deployed pool|


### set_pool_implementations

Set implementation contracts for pools


```solidity
function set_pool_implementations(uint256 _implementation_index, address _implementation) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_implementation_index`|`uint256`|Implementation index where implementation is stored|
|`_implementation`|`address`|Implementation address to use when deploying plain pools|


### set_metapool_implementations

Set implementation contracts for metapools


```solidity
function set_metapool_implementations(uint256 _implementation_index, address _implementation) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_implementation_index`|`uint256`|Implementation index where implementation is stored|
|`_implementation`|`address`|Implementation address to use when deploying metapools|


### set_math_implementation

Set implementation contract for StableSwap Math


```solidity
function set_math_implementation(address _math_implementation) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_math_implementation`|`address`|Address of the math implementation contract|


### set_views_implementation

Set implementation contract for Views methods


```solidity
function set_views_implementation(address _views_implementation) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_views_implementation`|`address`|Implementation address of views contract|


### set_gauge_implementation

Set gauge implementation address


```solidity
function set_gauge_implementation(address _gauge_implementation) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_gauge_implementation`|`address`|Address of the gauge implementation|


### admin

Returns the admin address


```solidity
function admin() external view returns (address);
```

### fee_receiver

Returns the fee receiver address


```solidity
function fee_receiver() external view returns (address);
```

### math_implementation

Returns the math implementation address


```solidity
function math_implementation() external view returns (address);
```

### views_implementation

Returns the views implementation address


```solidity
function views_implementation() external view returns (address);
```

### pool_implementations

Returns the pool implementation at the given index


```solidity
function pool_implementations(uint256 index) external view returns (address);
```

### pool_count

Returns the number of deployed pools


```solidity
function pool_count() external view returns (uint256);
```

### pool_list

Returns the pool address at the given index


```solidity
function pool_list(uint256 index) external view returns (address);
```

### is_meta

Check if a pool is a metapool


```solidity
function is_meta(address _pool) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Address of the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if the pool is a metapool|


