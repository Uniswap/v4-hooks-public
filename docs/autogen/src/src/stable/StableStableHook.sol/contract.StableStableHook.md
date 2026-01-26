# StableStableHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/56d233d0b250177bdf941e4e02adb122dab011ae/src/stable/StableStableHook.sol)

**Inherits:**
[FeeConfiguration](/src/stable/base/FeeConfiguration.sol/abstract.FeeConfiguration.md), [BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md), Ownable, Multicall, [IStableStableHook](/src/stable/interfaces/IStableStableHook.sol/interface.IStableStableHook.md)

**Title:**
StableStableHook

Dynamic fee hook for stable/stable pools


## State Variables
### TO_UNISWAP_FEE

```solidity
uint256 private constant TO_UNISWAP_FEE = ONE / 1e6
```


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


```solidity
function _beforeInitialize(address sender, PoolKey calldata, uint160) internal pure override returns (bytes4);
```

### _beforeSwap


```solidity
function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

### _getSqrtPriceX96


```solidity
function _getSqrtPriceX96(PoolId _poolId) internal view returns (uint256);
```

