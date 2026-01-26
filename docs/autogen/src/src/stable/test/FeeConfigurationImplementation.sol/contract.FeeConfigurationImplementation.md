# FeeConfigurationImplementation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/52da5b5343d128438b4f25057129e9ba4367d580/src/stable/test/FeeConfigurationImplementation.sol)

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

