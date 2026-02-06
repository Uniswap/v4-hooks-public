# IStETH
[Git Source](https://github.com/Uniswap/v4-hooks/blob/fc918c4c3fa3e5afc89d09732574ed28bc7c5602/src/interfaces/IWstETH.sol)


## Functions
### getSharesByPooledEth


```solidity
function getSharesByPooledEth(uint256 stEthAmount) external view returns (uint256);
```

### getPooledEthByShares


```solidity
function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);
```

### sharesOf


```solidity
function sharesOf(address _account) external view returns (uint256);
```

### transferShares


```solidity
function transferShares(address recipient, uint256 shares) external;
```

### balanceOf


```solidity
function balanceOf(address _account) external view returns (uint256);
```

