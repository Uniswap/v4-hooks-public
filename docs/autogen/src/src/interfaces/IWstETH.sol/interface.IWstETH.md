# IWstETH
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/510f5fe7d91535158cac5795bb284c347ddb8126/src/interfaces/IWstETH.sol)


## Functions
### wrap


```solidity
function wrap(uint256 _stETHAmount) external returns (uint256);
```

### unwrap


```solidity
function unwrap(uint256 _wstETHAmount) external returns (uint256);
```

### getStETHByWstETH


```solidity
function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
```

### getWstETHByStETH


```solidity
function getWstETHByStETH(uint256 _stETHAmount) external view returns (uint256);
```

### tokensPerStEth


```solidity
function tokensPerStEth() external view returns (uint256);
```

### stEthPerToken


```solidity
function stEthPerToken() external view returns (uint256);
```

### stETH


```solidity
function stETH() external view returns (address);
```

