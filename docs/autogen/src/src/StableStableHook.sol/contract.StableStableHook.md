# StableStableHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/00b4a9284d98f4fa6a7f5ae7ea60f3ee50fd746d/src/StableStableHook.sol)

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
error InvalidHookAddress(address invalid, address expected);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`invalid`|`address`|The invalid hook address|
|`expected`|`address`|address(this)|

### InvalidInitializer
Error thrown when the caller of `initializePool` is not address(this)


```solidity
error InvalidInitializer(address caller, address expected);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|The invalid address attempting to initialize the pool|
|`expected`|`address`|address(this)|

