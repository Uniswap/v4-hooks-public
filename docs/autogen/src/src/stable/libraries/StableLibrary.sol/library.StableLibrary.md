# StableLibrary
[Git Source](https://github.com/Uniswap/v4-hooks/blob/00674b730d2e683e2e0113e347bb7dc3b38fc03b/src/stable/libraries/StableLibrary.sol)

**Author:**
Modified from Solady (https://github.com/vectorized/solady/blob/main/src/utils/FixedPointMathLib.sol)


## Functions
### min

Returns the minimum of `x` and `y`.


```solidity
function min(uint256 x, uint256 y) internal pure returns (uint256 z);
```

### max

Returns the maximum of `x` and `y`.


```solidity
function max(int256 x, int256 y) internal pure returns (int256 z);
```

### fastPow


```solidity
function fastPow(uint256 k, uint256 blocksPassed) internal pure returns (uint256 z);
```

