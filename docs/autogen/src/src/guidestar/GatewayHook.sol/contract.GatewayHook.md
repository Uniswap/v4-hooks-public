# GatewayHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/af82e7dad988a6dbd52b8a924edb99094802d853/src/guidestar/GatewayHook.sol)

**Inherits:**
Ownable, [BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md)

**Title:**
GatewayHook


## State Variables
### implementation
The implementation address to forward calls to


```solidity
IHooks public implementation
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, address _initialOwner) BaseHook(_poolManager);
```

### setImplementation

Sets the implementation to forward calls to


```solidity
function setImplementation(IHooks _newImplementation) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_newImplementation`|`IHooks`|The new implementation address|


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
function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtAmmPrice)
    internal
    override
    returns (bytes4);
```

### _beforeSwap


```solidity
function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

## Errors
### MustUseDynamicFee
Thrown when the PoolKey's fee is not set to DYNAMIC_FEE_FLAG


```solidity
error MustUseDynamicFee();
```

