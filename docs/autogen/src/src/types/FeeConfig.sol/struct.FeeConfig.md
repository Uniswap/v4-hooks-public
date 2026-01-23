# FeeConfig
[Git Source](https://github.com/Uniswap/v4-hooks/blob/cc39bad2f9286aefd0824c4bc93d241fe8657275/src/types/FeeConfig.sol)

The fee configuration for each pool


```solidity
struct FeeConfig {
uint256 decayFactor;
uint24 optimalFeeRate;
uint160 referenceSqrtPriceX96;
}
```

