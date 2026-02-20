# FeeConfigurationImplementation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/6f0bc048cd23c50aa10d7002608266ee2d62bb42/src/stable/test/FeeConfigurationImplementation.sol)

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

