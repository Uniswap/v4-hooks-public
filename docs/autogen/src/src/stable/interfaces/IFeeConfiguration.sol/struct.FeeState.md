# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks/blob/7dcd775c7e3ae809200c0a0161e8e569c246c698/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 previousFeeE12; // Last flexible fee charged in 1e12 precision; used for exponential decay calculation
uint160 previousSqrtAmmPriceX96; // AMM sqrt price at last swap; used to detect price movement direction
uint256 blockNumber; // Block when fee was last updated; determines decay based on blocks elapsed
}
```

