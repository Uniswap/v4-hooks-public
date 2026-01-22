# StableStableHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/42f0f4c9ee15cb6b951d3e798fb2c00c2fd84420/src/StableStableHook.sol)

**Inherits:**
[BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md), Ownable, Multicall, [IStableStableHook](/src/interfaces/IStableStableHook.sol/interface.IStableStableHook.md)

**Title:**
StableStableHook

Dynamic fee hook for stable/stable pools


## State Variables
### feeConfig
The fee configuration for each pool


```solidity
mapping(PoolId => FeeConfig) public feeConfig
```


### historicalFeeData
The historical data for each pool


```solidity
mapping(PoolId => HistoricalFeeData) public historicalFeeData
```


### feeController
The address of the fee controller

The fee controller is the address that can update the fee configuration for a pool


```solidity
address public immutable feeController
```


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, address _owner, address _feeController) BaseHook(_manager) Ownable(_owner);
```

### onlyFeeController

Modifier to only allow calls from the fee controller

This modifier is used to prevent unauthorized updates to the fee configuration per pool


```solidity
modifier onlyFeeController() ;
```

### initializePool

Initialize a Uniswap v4 pool


```solidity
function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, FeeConfig calldata feeConfiguration)
    external
    onlyOwner
    returns (int24 tick);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to initialize|
|`sqrtPriceX96`|`uint160`|The initial starting price of the pool, expressed as a sqrtPriceX96|
|`feeConfiguration`|`FeeConfig`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tick`|`int24`|The current tick of the pool|


### updateDecayFactor

Update the decay factor for a pool

Should be called in a multicall with clearHistoricalFeeData()


```solidity
function updateDecayFactor(PoolKey calldata poolKey, uint256 decayFactor) external onlyFeeController;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the decay factor for|
|`decayFactor`|`uint256`|The new decay factor|


### updateOptimalFeeSpread

Update the optimal fee spread for a pool

Should be called in a multicall with clearHistoricalFeeData()


```solidity
function updateOptimalFeeSpread(PoolKey calldata poolKey, uint256 optimalFeeSpread) external onlyFeeController;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the optimal fee spread for|
|`optimalFeeSpread`|`uint256`|The new optimal fee spread|


### updateReferenceSqrtPrice

Update the reference sqrt price for a pool

Should be called in a multicall with clearHistoricalFeeData()


```solidity
function updateReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPrice) external onlyFeeController;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to update the reference sqrt price for|
|`referenceSqrtPrice`|`uint160`|The new reference sqrt price|


### clearHistoricalFeeData

Clear the historical data for a pool


```solidity
function clearHistoricalFeeData(PoolKey calldata poolKey) external onlyFeeController;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to clear the historical data for|


### getHookPermissions

Returns a struct of permissions to signal which hook functions are to be implemented

Used at deployment to validate the address correctly represents the expected permissions


```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`Hooks.Permissions`|Permissions struct|


### _beforeInitialize


```solidity
function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4);
```

### _beforeSwap


```solidity
function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
    internal
    pure
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

### _validateDecayFactor


```solidity
function _validateDecayFactor(uint256 _decayFactor) internal pure;
```

### _validateOptimalFeeSpread


```solidity
function _validateOptimalFeeSpread(uint256 _optimalFeeSpread) internal pure;
```

### _validateReferenceSqrtPrice


```solidity
function _validateReferenceSqrtPrice(uint160 _referenceSqrtPrice) internal pure;
```

