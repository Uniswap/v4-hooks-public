# FeeConfigurationImplementation
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/17d7d5811380e775c83dd0663f30fb95c53d02b9/src/stable/test/FeeConfigurationImplementation.sol)

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

