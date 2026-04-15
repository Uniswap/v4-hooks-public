# PermissionedHooks
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/1f52c3f85ae2e6c0f55bd2f364a64854ec0b34bc/src/permissioned-pools/PermissionedHooks.sol)

**Inherits:**
IHooks, [BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md)


## State Variables
### PERMISSIONS_ADAPTER_FACTORY

```solidity
IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY
```


## Functions
### constructor


```solidity
constructor(IPoolManager manager, IPermissionsAdapterFactory permissionsAdapterFactory) BaseHook(manager);
```

### getHookPermissions

Returns the hook permissions configuration for this contract


```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions);
```

### _beforeInitialize

Requires at least one pool currency to be a verified permissions adapter


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4);
```

### _beforeSwap

Does not need to verify msg.sender address directly, as verifying the allowlist is sufficient due to the fact that any valid senders are allowed wrappers


```solidity
function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
    internal
    view
    override
    returns (bytes4 selector, BeforeSwapDelta, uint24);
```

### _beforeAddLiquidity

Does not need to verify msg.sender address directly, as verifying the allowlist is sufficient due to the fact that any valid senders are allowed wrappers


```solidity
function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
    internal
    view
    override
    returns (bytes4 selector);
```

### _verifyAllowlist

checks if the sender is allowed to access both tokens in the pool


```solidity
function _verifyAllowlist(IMsgSender sender, PoolKey calldata poolKey, bytes4 selector) internal view;
```

### _isAllowed

checks if the provided token is a permissioned token by checking if it has a verified permissions adapter, if yes, check the allowlist and check whether swapping is enabled


```solidity
function _isAllowed(address permissionsAdapter, address sender, address router, bytes4 selector) internal view;
```

## Errors
### Unauthorized

```solidity
error Unauthorized();
```

### SwappingDisabled

```solidity
error SwappingDisabled();
```

### NoVerifiedAdapter

```solidity
error NoVerifiedAdapter();
```

