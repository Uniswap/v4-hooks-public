# StableStableHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/41c71a048fa24d78a5635a90a45ac5309c241613/src/stable/StableStableHook.sol)

**Inherits:**
[FeeConfiguration](/src/stable/base/FeeConfiguration.sol/abstract.FeeConfiguration.md), [BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md), Ownable, [IStableStableHook](/src/stable/interfaces/IStableStableHook.sol/interface.IStableStableHook.md)

**Title:**
StableStableHook

Dynamic fee hook for stable/stable pools

**Note:**
security-contact: security@uniswap.org


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, address _owner, address _configManager)
    FeeConfiguration(_configManager)
    Ownable(_owner)
    BaseHook(_manager);
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

Reject initialization of the pool by another address


```solidity
function _beforeInitialize(address sender, PoolKey calldata, uint160) internal pure override returns (bytes4);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sender`|`address`|The address that attempted to initialize the pool (not address(this))|
|`<none>`|`PoolKey`||
|`<none>`|`uint160`||


### _beforeSwap

Calculate and apply dynamic fee before each swap


```solidity
function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`||
|`key`|`PoolKey`|The PoolKey of the pool|
|`params`|`SwapParams`|The SwapParams of the swap|
|`<none>`|`bytes`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes4`|selector The function selector for IHooks.beforeSwap|
|`<none>`|`BeforeSwapDelta`|delta BeforeSwapDelta (always zero for this hook)|
|`<none>`|`uint24`|lpFeeOverride The calculated dynamic fee with override flag|


### _calculateDecayingFee

Calculate decaying fee when price is outside optimal range


```solidity
function _calculateDecayingFee(
    FeeConfig storage config,
    FeeState storage feeState,
    uint256 sqrtAmmPriceX96,
    uint256 sqrtReferencePriceX96,
    uint256 closeBoundaryFeeE12,
    uint256 farBoundaryFeeE12,
    bool ammPriceToTheLeft
) private view returns (uint256 decayingFeeE12);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`config`|`FeeConfig`|The FeeConfig of the pool|
|`feeState`|`FeeState`|The FeeState of the pool|
|`sqrtAmmPriceX96`|`uint256`|The current AMM sqrt price|
|`sqrtReferencePriceX96`|`uint256`|The reference sqrt price|
|`closeBoundaryFeeE12`|`uint256`|The fee to reach the close boundary of the optimal range (negative = already inside)|
|`farBoundaryFeeE12`|`uint256`|The fee to reach the far boundary of the optimal range|
|`ammPriceToTheLeft`|`bool`|True if current AMM price < reference price|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`decayingFeeE12`|`uint256`|The calculated decaying fee in 1e12 precision|


