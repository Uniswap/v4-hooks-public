# ICurveFactory
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/37a7cb81b7d428c0f0c3a3b22f8af4d012f72874/src/aggregator-hooks/implementations/StableSwap/interfaces/ICurveFactory.sol)

**Title:**
ICurveFactory

Interface for Curve Metapool Factory

Based on the factory at https://github.com/curvefi/curve-factory/blob/master/contracts/Factory.vy


## Functions
### deploy_plain_pool

Deploy a new plain pool with all parameters (selector: 0x52f2db69)


```solidity
function deploy_plain_pool(
    string memory _name,
    string memory _symbol,
    address[4] memory _coins,
    uint256 _A,
    uint256 _fee,
    uint256 _asset_type,
    uint256 _implementation_idx
) external returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_name`|`string`|Name of the new plain pool|
|`_symbol`|`string`|Symbol for the new plain pool's LP token|
|`_coins`|`address[4]`|Fixed array of 4 coin addresses (use address(0) for unused slots)|
|`_A`|`uint256`|Amplification coefficient|
|`_fee`|`uint256`|Trade fee with 1e10 precision (min 0.04% = 4000000, max 1% = 100000000)|
|`_asset_type`|`uint256`|Asset type (0=USD, 1=ETH, 2=BTC, 3=Other)|
|`_implementation_idx`|`uint256`|Index of the implementation to use|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The address of the deployed pool|


### deploy_plain_pool

Deploy a new plain pool with asset_type, impl_idx defaults to 0 (selector: 0x5c16487b)


```solidity
function deploy_plain_pool(
    string memory _name,
    string memory _symbol,
    address[4] memory _coins,
    uint256 _A,
    uint256 _fee,
    uint256 _asset_type
) external returns (address);
```

### deploy_plain_pool

Deploy a new plain pool with defaults for asset_type and impl_idx (selector: 0xcd419bb5)


```solidity
function deploy_plain_pool(
    string memory _name,
    string memory _symbol,
    address[4] memory _coins,
    uint256 _A,
    uint256 _fee
) external returns (address);
```

### deploy_metapool

Deploy a new metapool


```solidity
function deploy_metapool(
    address _base_pool,
    string memory _name,
    string memory _symbol,
    address _coin,
    uint256 _A,
    uint256 _fee,
    uint256 _implementation_idx
) external returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_base_pool`|`address`|Address of the base pool to pair with|
|`_name`|`string`|Name of the new metapool|
|`_symbol`|`string`|Symbol for the new metapool's LP token|
|`_coin`|`address`|Address of the coin being used in the metapool|
|`_A`|`uint256`|Amplification coefficient|
|`_fee`|`uint256`|Trade fee with 1e10 precision|
|`_implementation_idx`|`uint256`|Index of the implementation to use|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The address of the deployed metapool|


### plain_implementations

Get plain pool implementation address


```solidity
function plain_implementations(uint256 n_coins, uint256 idx) external view returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`n_coins`|`uint256`|Number of coins in the pool|
|`idx`|`uint256`|Implementation index|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|Implementation address|


### metapool_implementations

Get metapool implementations for a base pool


```solidity
function metapool_implementations(address _base_pool) external view returns (address[10] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_base_pool`|`address`|Base pool address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address[10]`|Array of implementation addresses|


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

### get_implementation_address

Get implementation address for a pool


```solidity
function get_implementation_address(address _pool) external view returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Pool address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|Implementation address|


### get_coins

Get coins in a pool


```solidity
function get_coins(address _pool) external view returns (address[4] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Pool address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address[4]`|Array of coin addresses|


### get_n_coins

Get number of coins in a pool


```solidity
function get_n_coins(address _pool) external view returns (uint256[2] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Pool address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256[2]`|Number of coins and underlying coins|


### get_balances

Get balances of coins in a pool


```solidity
function get_balances(address _pool) external view returns (uint256[4] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Pool address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256[4]`|Array of balances|


