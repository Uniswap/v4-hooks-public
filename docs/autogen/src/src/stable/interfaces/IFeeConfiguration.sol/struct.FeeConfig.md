# FeeConfig
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/2906ec0c427bcf81632102bfdde9ba69213d4800/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeConfig {
uint24 k; // Decay factor per block in Q24 format (e.g., 0.99 in Q24 means fee retains 99% of its value each block)
uint24 logK; // Precomputed -ln(k) >> 40; used for > 4 blocks decay: k^n = exp(-logK * n)
uint24 optimalFeeE6; // Fee rate defining optimal range width in PRICE space (not sqrt price), 1e6 precision
uint8 targetMultiplier; // Multiplier for target fee: targetFee = farBoundaryFee - closeBoundaryFee * targetMultiplier / 100. Must be 0-100.
uint160 referenceSqrtPriceX96; // Reference center point in sqrt Q96 format
}
```

