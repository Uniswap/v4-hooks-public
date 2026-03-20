# IStETH
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/17d7d5811380e775c83dd0663f30fb95c53d02b9/src/interfaces/IWstETH.sol)


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

