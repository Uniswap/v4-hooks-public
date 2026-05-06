# PancakeSwapV3Aggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/dcbc3eebe37e6bd7a961e941367bd261e93d818d/src/aggregator-hooks/implementations/PancakeSwapV3/PancakeSwapV3Aggregator.sol)

**Inherits:**
[UniswapV3Aggregator](/src/aggregator-hooks/implementations/UniswapV3/UniswapV3Aggregator.sol/contract.UniswapV3Aggregator.md), [IPancakeSwapV3Callback](/src/aggregator-hooks/implementations/PancakeSwapV3/interfaces/IPancakeSwapV3Callback.sol/interface.IPancakeSwapV3Callback.md)

Same as UniswapV3Aggregator but implements PancakeSwap V3 swap callback ABI


## Functions
### constructor


```solidity
constructor(IPoolManager manager, address factory_, string memory hookVersion)
    UniswapV3Aggregator(manager, factory_, hookVersion);
```

### pancakeV3SwapCallback


```solidity
function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override;
```

