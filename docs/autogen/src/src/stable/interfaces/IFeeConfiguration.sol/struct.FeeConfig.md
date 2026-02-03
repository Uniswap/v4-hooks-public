# FeeConfig
[Git Source](https://github.com/Uniswap/v4-hooks/blob/7dcd775c7e3ae809200c0a0161e8e569c246c698/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeConfig {
uint256 k; // Decay rate per block; controls how fast fees decrease toward target
uint256 logK; // Used for efficient decay calculation over many blocks
uint24 optimalFeeRateE6; // Optimal rate width in 1e6 precision; inside = consistent buy/sell prices, outside = flexible
uint160 referenceSqrtPriceX96; // Reference sqrt price; optimal rate centered around this
}
```

