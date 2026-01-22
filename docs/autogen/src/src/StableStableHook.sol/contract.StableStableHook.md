# StableStableHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/ef9808384cab8e369c1005cc3519542d59621d1c/src/StableStableHook.sol)

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
function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4);
```

### _beforeSwap


```solidity
function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
    internal
    pure
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

