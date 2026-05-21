# FeeConfigurationImplementation
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/fb38bd58a3855b38f1e6e41a9ca471e83744f2b7/src/stable/test/FeeConfigurationImplementation.sol)

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

