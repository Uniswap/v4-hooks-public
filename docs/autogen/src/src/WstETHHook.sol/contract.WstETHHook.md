# WstETHHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/f59df65aac634225df286566d7903789d79f680c/src/WstETHHook.sol)

**Inherits:**
[BaseTokenWrapperHook](/src/base/BaseTokenWrapperHook.sol/abstract.BaseTokenWrapperHook.md)

**Title:**
Wrapped Staked ETH (wstETH) Hook

Hook for wrapping/unwrapping stETH/wstETH in Uniswap V4 pools

Implements dynamic exchange rate wrapping/unwrapping between stETH and wstETH

wstETH represents stETH with accrued staking rewards, maintaining a dynamic exchange rate


## State Variables
### wstETH
The wstETH contract used for wrapping/unwrapping operations


```solidity
IWstETH public immutable wstETH
```


## Functions
### constructor

Creates a new wstETH wrapper hook

Initializes with wstETH as wrapper token and stETH as underlying token


```solidity
constructor(IPoolManager _manager, IWstETH _wsteth)
    BaseTokenWrapperHook(
        _manager,
        Currency.wrap(address(_wsteth)), // wrapper token is wstETH
        Currency.wrap(_wsteth.stETH()) // underlying token is stETH
    );
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_manager`|`IPoolManager`|The Uniswap V4 pool manager|
|`_wsteth`|`IWstETH`|The wstETH contract address|


### _deposit

Deposits underlying tokens to receive wrapper tokens

Implementing contracts should handle:


```solidity
function _deposit(uint256 underlyingAmount)
    internal
    virtual
    override
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
function _withdraw(uint256 wrapperAmount)
    internal
    override
    returns (uint256 actualWrappedAmount, uint256 actualUnwrappedAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`wrapperAmount`|`uint256`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`actualWrappedAmount`|`uint256`|the actual number of wrapped tokens used, i.e. to account for rebasing rounding errors|
|`actualUnwrappedAmount`|`uint256`|underlyingAmount The amount of underlying tokens received|


### _getWrapInputRequired

Calculates how much stETH is needed to receive a specific amount of wstETH

Uses current stETH/wstETH exchange rate for calculation


```solidity
function _getWrapInputRequired(uint256 wrappedAmount) internal view override returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`wrappedAmount`|`uint256`|Desired amount of wstETH|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Amount of stETH required|


### _getUnwrapInputRequired

Calculates how much wstETH is needed to receive a specific amount of stETH

Uses current stETH/wstETH exchange rate for calculation


```solidity
function _getUnwrapInputRequired(uint256 underlyingAmount) internal view override returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`underlyingAmount`|`uint256`|Desired amount of stETH|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Amount of wstETH required|


### _supportsExactOutput

Indicates whether the hook supports exact output swaps

Default implementation returns true


```solidity
function _supportsExactOutput() internal pure override returns (bool);
```

