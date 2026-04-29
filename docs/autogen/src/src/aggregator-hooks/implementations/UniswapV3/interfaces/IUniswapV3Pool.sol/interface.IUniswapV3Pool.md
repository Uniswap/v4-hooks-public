# IUniswapV3Pool
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/8f2591d7920c37c7febdcff1c1ab7aa7c00d922f/src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3Pool.sol)

**Title:**
IUniswapV3Pool

Minimal Uniswap V3 compatible pool interface


## Functions
### token0


```solidity
function token0() external view returns (address);
```

### token1


```solidity
function token1() external view returns (address);
```

### fee


```solidity
function fee() external view returns (uint24);
```

### tickSpacing


```solidity
function tickSpacing() external view returns (int24);
```

### swap


```solidity
function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
) external returns (int256 amount0, int256 amount1);
```

