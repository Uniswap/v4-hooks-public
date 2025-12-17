# BaseTokenWrapperHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/db91a2c77b66fec3dbf96f155f47b911e1de18e8/src/base/BaseTokenWrapperHook.sol)

**Inherits:**
[BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md), DeltaResolver

**Title:**
Base Token Wrapper Hook

Abstract base contract for implementing token wrapper hooks in Uniswap V4

This contract provides the base functionality for wrapping/unwrapping tokens through V4 pools

All liquidity operations are blocked as liquidity is managed through the underlying token wrapper

Implementing contracts must provide deposit() and withdraw() functions


## State Variables
### wrapperCurrency
The wrapped token currency (e.g., WETH)


```solidity
Currency public immutable wrapperCurrency
```


### underlyingCurrency
The underlying token currency (e.g., ETH)


```solidity
Currency public immutable underlyingCurrency
```


### wrapZeroForOne
Indicates whether wrapping occurs when swapping from token0 to token1

This is determined by the relative ordering of the wrapper and underlying tokens

If true: token0 is underlying (e.g. ETH) and token1 is wrapper (e.g. WETH)

If false: token0 is wrapper (e.g. WETH) and token1 is underlying (e.g. ETH)

This is set in the constructor based on the token addresses to ensure consistent behavior


```solidity
bool public immutable wrapZeroForOne
```


## Functions
### constructor

Creates a new token wrapper hook


```solidity
constructor(IPoolManager _manager, Currency _wrapper, Currency _underlying) BaseHook(_manager);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_manager`|`IPoolManager`|The Uniswap V4 pool manager|
|`_wrapper`|`Currency`|The wrapped token currency (e.g., WETH)|
|`_underlying`|`Currency`|The underlying token currency (e.g., ETH)|


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

Validates pool initialization parameters

Ensures pool contains wrapper and underlying tokens with zero fee


```solidity
function _beforeInitialize(address, PoolKey calldata poolKey, uint160) internal view override returns (bytes4);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`||
|`poolKey`|`PoolKey`|The pool configuration including tokens and fee|
|`<none>`|`uint160`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes4`|The function selector if validation passes|


### _beforeAddLiquidity

Prevents liquidity operations on wrapper pools

Always reverts as liquidity is managed through the token wrapper


```solidity
function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
    internal
    pure
    override
    returns (bytes4);
```

### _beforeSwap

Handles token wrapping and unwrapping during swaps

Processes both exact input (amountSpecified < 0) and exact output (amountSpecified > 0) swaps


```solidity
function _beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
    internal
    override
    returns (bytes4, BeforeSwapDelta swapDelta, uint24);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`||
|`<none>`|`PoolKey`||
|`params`|`SwapParams`|The swap parameters including direction and amount|
|`<none>`|`bytes`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes4`|selector The function selector|
|`swapDelta`|`BeforeSwapDelta`|The input/output token amounts for pool accounting|
|`<none>`|`uint24`|lpFeeOverride The fee override (always 0 for wrapper pools)|


### _pay

Transfers tokens to the pool manager

The recipient of the payment should be the poolManager


```solidity
function _pay(Currency token, address, uint256 amount) internal override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`Currency`|The token to transfer|
|`<none>`|`address`||
|`amount`|`uint256`|The amount to transfer|


### _deposit

Deposits underlying tokens to receive wrapper tokens

Implementing contracts should handle:


```solidity
function _deposit(uint256 underlyingAmount)
    internal
    virtual
    returns (uint256 actualUnderlyingAmount, uint256 wrappedAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`underlyingAmount`|`uint256`|The amount of underlying tokens to deposit|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`actualUnderlyingAmount`|`uint256`|the actual number of underlying tokens used, i.e. to account for rebasing rounding errors|
|`wrappedAmount`|`uint256`|The amount of wrapper tokens received|


### _withdraw

Withdraws wrapper tokens to receive underlying tokens

Implementing contracts should handle:


```solidity
function _withdraw(uint256 wrappedAmount)
    internal
    virtual
    returns (uint256 actualWrappedAmount, uint256 underlyingAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`wrappedAmount`|`uint256`|The amount of wrapper tokens to withdraw|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`actualWrappedAmount`|`uint256`|the actual number of wrapped tokens used, i.e. to account for rebasing rounding errors|
|`underlyingAmount`|`uint256`|The amount of underlying tokens received|


### _getWrapInputRequired

Calculates underlying tokens needed to receive desired wrapper tokens

Default implementation assumes 1:1 ratio

Override for wrappers with different exchange rates


```solidity
function _getWrapInputRequired(uint256 wrappedAmount) internal view virtual returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`wrappedAmount`|`uint256`|The desired amount of wrapper tokens|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The required amount of underlying tokens|


### _getUnwrapInputRequired

Calculates wrapper tokens needed to receive desired underlying tokens

Default implementation assumes 1:1 ratio

Override for wrappers with different exchange rates


```solidity
function _getUnwrapInputRequired(uint256 underlyingAmount) internal view virtual returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`underlyingAmount`|`uint256`|The desired amount of underlying tokens|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The required amount of wrapper tokens|


### _supportsExactOutput

Indicates whether the hook supports exact output swaps

Default implementation returns true

Override for wrappers that cannot support exact output swaps


```solidity
function _supportsExactOutput() internal view virtual returns (bool);
```

### _supportsExactInput

Indicates whether the hook supports exact input swaps

Default implementation returns true

Override for wrappers that cannot support exact input swaps


```solidity
function _supportsExactInput() internal view virtual returns (bool);
```

## Errors
### LiquidityNotAllowed
Thrown when attempting to add or remove liquidity

Liquidity operations are blocked since all liquidity is managed by the token wrapper


```solidity
error LiquidityNotAllowed();
```

### InvalidPoolToken
Thrown when initializing a pool with invalid tokens

Pool must contain exactly one wrapper token and its underlying token


```solidity
error InvalidPoolToken();
```

### InvalidPoolFee
Thrown when initializing a pool with non-zero fee

Fee must be 0 as wrapper pools don't charge fees


```solidity
error InvalidPoolFee();
```

### ExactInputNotSupported
Thrown when exact input swaps are not supported


```solidity
error ExactInputNotSupported();
```

### ExactOutputNotSupported
Thrown when exact output swaps are not supported


```solidity
error ExactOutputNotSupported();
```

