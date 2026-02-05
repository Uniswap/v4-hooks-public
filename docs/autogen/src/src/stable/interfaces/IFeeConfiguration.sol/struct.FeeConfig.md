# FeeConfig
[Git Source](https://github.com/Uniswap/v4-hooks/blob/ed81fe2a4a0d3051e856ceb7db85c49785fdfa56/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeConfig {
uint24 k; // Decay factor per block in Q24 format (e.g., 0.99 in Q24 means fee retains 99% of its value each block)
uint24 logK; // Precomputed -ln(k) >> 40; used for > 4 blocks decay: k^n = exp(-logK * n)
uint24 optimalFeeE6; // Optimal fee when amm price = reference price in 1e6 precision
uint160 referenceSqrtPriceX96; // Reference center point in sqrt Q96 format
}
```

