# PermissionedHooks
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/0d80526d11c0689c2c79f9b7848f43b9357c02e9/src/permissioned-pools/PermissionedHooks.sol)

**Inherits:**
IHooks, [BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md)

**Title:**
PermissionedHooks

Enforces per-currency allowlist on pools containing permissioned tokens.

Trusts wrapper-reported `msgSender()`; wrappers must be registered in adapter `allowedWrappers`.


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

Requires at least one pool currency to be a verified permissions adapter, and disallows
any pool currency that is an unverified permissions adapter.


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

### _afterSwap

Emits a Swap event so indexers can track activity on permissioned pools.


```solidity
function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
    internal
    override
    returns (bytes4, int128);
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

## Events
### Swap
Emitted after a swap through a permissioned pool. Mirrors `IV4Router.Swap` so that
indexers can track swaps on permissioned pools with the same schema as the standard router.


```solidity
event Swap(
    PoolId indexed id,
    address indexed sender,
    int128 amount0,
    int128 amount1,
    uint160 sqrtPriceX96,
    uint128 liquidity,
    int24 tick,
    uint24 fee
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`id`|`PoolId`|The pool the swap occurred on|
|`sender`|`address`|The originator of the swap|
|`amount0`|`int128`|The signed change in currency0 balance from the pool's perspective|
|`amount1`|`int128`|The signed change in currency1 balance from the pool's perspective|
|`sqrtPriceX96`|`uint160`|The pool's sqrt price after the swap|
|`liquidity`|`uint128`|The pool's active liquidity after the swap|
|`tick`|`int24`|The pool's tick after the swap|
|`fee`|`uint24`|The pool's swap fee at the time of the swap|

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

### UnverifiedAdapter

```solidity
error UnverifiedAdapter();
```

