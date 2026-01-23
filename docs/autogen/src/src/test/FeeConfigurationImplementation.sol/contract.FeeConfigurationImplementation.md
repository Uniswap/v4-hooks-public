# FeeConfigurationImplementation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/cc39bad2f9286aefd0824c4bc93d241fe8657275/src/test/FeeConfigurationImplementation.sol)

**Inherits:**
[FeeConfiguration](/src/FeeConfiguration.sol/abstract.FeeConfiguration.md)

**Title:**
FeeConfigurationImplementation

Implementation of the FeeConfiguration contract


## Functions
### constructor


```solidity
constructor(address _feeController) FeeConfiguration(_feeController);
```

### _getFeeConfig


```solidity
function _getFeeConfig(PoolKey calldata poolKey) internal view override returns (FeeConfig storage);
```

### _getHistoricalFeeData


```solidity
function _getHistoricalFeeData(PoolKey calldata poolKey)
    internal
    view
    override
    returns (HistoricalFeeData storage);
```

