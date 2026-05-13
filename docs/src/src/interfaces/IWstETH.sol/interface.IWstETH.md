# IWstETH
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/2be48d7f4fbdc30390a03b6da2febe82639b089c/src/interfaces/IWstETH.sol)


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

