# FeeConfigurationImplementation
[Git Source](https://github.com/Uniswap/v4-hooks/blob/ec3cfb721a3661c7406618f534d9ae8887a128c1/src/test/FeeConfigurationImplementation.sol)

**Inherits:**
[FeeConfiguration](/src/FeeConfiguration.sol/abstract.FeeConfiguration.md)

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

