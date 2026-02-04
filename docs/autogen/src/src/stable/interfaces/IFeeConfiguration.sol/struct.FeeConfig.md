# FeeConfig
[Git Source](https://github.com/Uniswap/v4-hooks/blob/212d67197db95402e0c7050941534ae8c084bb31/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeConfig {
uint24 k; // Decay rate per block in Q24 format (2^24 = 1.0). E.g., 0.99 decays 1% per block.
uint24 logK; // -ln(k) >> 40; precomputed for efficient multi-block decay via exp(-logK * blocks)
uint24 optimalFeeE6; // Optimal fee when amm price = reference price in 1e6 precision
uint160 referenceSqrtPriceX96; // Reference center point in sqrt Q96 format
}
```

