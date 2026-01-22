# StableStableHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/faae6bc83a1d5c7c0278e78d82941054e5cbd26f/src/StableStableHook.sol)

**Inherits:**
[BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md), Ownable

**Title:**
StableStableHook

Dynamic fee hook for stable/stable pools


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, address _owner) BaseHook(_manager) Ownable(_owner);
```

### initializePool

Initialize a Uniswap v4 pool


```solidity
function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96) external onlyOwner returns (int24 tick);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The PoolKey of the pool to initialize|
|`sqrtPriceX96`|`uint160`|The initial starting price of the pool, expressed as a sqrtPriceX96|

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

## Errors
### MustUseDynamicFee
Error thrown when the pool trying to be initialized is not using a dynamic fee


```solidity
error MustUseDynamicFee(uint24 lpFee);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lpFee`|`uint24`|The LP fee that was used to try to initialize the pool|

### InvalidHookAddress
Error thrown when the hook address is not address(this)


```solidity
error InvalidHookAddress(address hookAddress);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`hookAddress`|`address`|The invalid hook address|

### InvalidInitializer
Error thrown when the caller of `initializePool` is not address(this)


```solidity
error InvalidInitializer(address caller);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|The invalid address attempting to initialize the pool|

