# FeeConfig
[Git Source](https://github.com/Uniswap/v4-hooks/blob/f1e6f575bfe1e9a74ff4f8105848ddf85efaaa12/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeConfig {
uint256 k; // Decay rate per block; controls how fast fees decrease toward target
uint256 logK; // Used for efficient decay calculation over many blocks
uint24 optimalFeeRate; // Optimal range width in 1e6 precision; inside = consistent buy/sell prices, outside = flexible
uint160 referenceSqrtPriceX96; // Reference sqrt price; optimal range centered around this
}
```

