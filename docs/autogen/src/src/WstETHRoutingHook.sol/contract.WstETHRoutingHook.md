# WstETHRoutingHook
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/56f51601c343010d27d45c492f27de85ad1a03d2/src/WstETHRoutingHook.sol)

**Inherits:**
[WstETHHook](/src/WstETHHook.sol/contract.WstETHHook.md)

A hook that allows simulating the WstETHHook with the v4 Quoter

*The WstETHHook takes the amount deposited by the swapper into the PoolManager and wraps it to wstETH. When simulating the WstETHHook, no underlying stETH are deposited into the PoolManager and the WstETHHook reverts. This hook acts as a replacement for the WstETHHook in the Quoter and calculates the amount of wstETH that would be minted by the WstETHHook, without executing the actual wrapping.*

*The withdraw function doesn't need to be overridden, as the PoolManager has a sufficient balance of WstETH to cover the withdrawal in the simulation.*


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, IWstETH _wstETH) WstETHHook(_poolManager, _wstETH);
```

### _deposit

Deposits underlying tokens to receive wrapper tokens

*Implementing contracts should handle:*


```solidity
function _deposit(uint256 underlyingAmount)
    internal
    view
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


