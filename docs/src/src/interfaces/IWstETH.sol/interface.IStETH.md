# IStETH
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0c68c6912ec9b3df692fd62740997db52f245b7d/src/interfaces/IWstETH.sol)


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

