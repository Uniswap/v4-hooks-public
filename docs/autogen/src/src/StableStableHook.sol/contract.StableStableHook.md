# StableStableHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/619dbe3ff1bd956d7247f5309c0553a3680ffe0a/src/StableStableHook.sol)

**Inherits:**
[BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md)

**Title:**
StableStableHook

Dynamic fee hook for stable/stable pools


## Functions
### constructor


```solidity
constructor(IPoolManager _manager) BaseHook(_manager);
```

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
function _beforeInitialize(address, PoolKey calldata poolKey, uint160) internal pure override returns (bytes4);
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
error MustUseDynamicFee();
```

