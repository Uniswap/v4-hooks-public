# IUniswapV2Pair
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/d636b0c2e723a4f3e275fde691adb8ea9a34eb83/src/aggregator-hooks/implementations/UniswapV2/interfaces/IUniswapV2Pair.sol)

Minimal subset of canonical Uniswap V2 pair surface


## Functions
### token0


```solidity
function token0() external view returns (address);
```

### token1


```solidity
function token1() external view returns (address);
```

### getReserves


```solidity
function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
```

### swap


```solidity
function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
```

