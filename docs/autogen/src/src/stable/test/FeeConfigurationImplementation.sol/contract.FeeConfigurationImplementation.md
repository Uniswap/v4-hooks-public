# FeeConfigurationImplementation
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/510f5fe7d91535158cac5795bb284c347ddb8126/src/stable/test/FeeConfigurationImplementation.sol)

**Inherits:**
[FeeConfiguration](/src/stable/base/FeeConfiguration.sol/abstract.FeeConfiguration.md)

**Title:**
FeeConfigurationImplementation

Implementation of the FeeConfiguration contract


## Functions
### constructor


```solidity
constructor(address _configManager) FeeConfiguration(_configManager);
```

### setFeeState

Test helper to set fee state directly


```solidity
function setFeeState(PoolId poolId, FeeState calldata _feeState) external;
```

