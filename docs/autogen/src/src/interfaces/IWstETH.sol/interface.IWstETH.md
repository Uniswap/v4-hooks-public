# IWstETH
[Git Source](https://github.com/Uniswap/v4-hooks/blob/fc918c4c3fa3e5afc89d09732574ed28bc7c5602/src/interfaces/IWstETH.sol)


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

