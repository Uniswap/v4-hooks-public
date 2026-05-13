# WETHHook
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/2be48d7f4fbdc30390a03b6da2febe82639b089c/src/WETHHook.sol)

**Inherits:**
[BaseTokenWrapperHook](/Users/david.rinconcruz/Uniswap/v4-hooks-public/docs/src/src/base/BaseTokenWrapperHook.sol/abstract.BaseTokenWrapperHook.md)

Hook for wrapping/unwrapping ETH in Uniswap V4 pools

Implements 1:1 wrapping/unwrapping of ETH to WETH


## State Variables
### weth
The WETH9 contract


```solidity
WETH public immutable weth
```


## Functions
### constructor

Creates a new WETH wrapper hook


```solidity
constructor(IPoolManager _manager, address payable _weth)
    BaseTokenWrapperHook(
        _manager,
        Currency.wrap(_weth), // wrapper token is WETH
        CurrencyLibrary.ADDRESS_ZERO // underlying token is ETH (address(0))
    );
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_manager`|`IPoolManager`|The Uniswap V4 pool manager|
|`_weth`|`address payable`|The WETH9 contract address|


### _deposit

Deposits underlying tokens to receive wrapper tokens

Note the WETH deposit relies on the WETH wrapper having a receive function that mints WETH to msg.sender


```solidity
function _deposit(uint256 underlyingAmount) internal override returns (uint256, uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`underlyingAmount`|`uint256`|The amount of underlying tokens to deposit|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|actualUnderlyingAmount the actual number of underlying tokens used, i.e. to account for rebasing rounding errors|
|`<none>`|`uint256`|wrappedAmount The amount of wrapper tokens received|


### _withdraw

Withdraws wrapper tokens to receive underlying tokens

Implementing contracts should handle:


```solidity
function _withdraw(uint256 wrapperAmount) internal override returns (uint256, uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`wrapperAmount`|`uint256`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|actualWrappedAmount the actual number of wrapped tokens used, i.e. to account for rebasing rounding errors|
|`<none>`|`uint256`|underlyingAmount The amount of underlying tokens received|


### receive

Required to receive ETH


```solidity
receive() external payable;
```

