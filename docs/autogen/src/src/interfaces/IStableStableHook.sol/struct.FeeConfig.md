# FeeConfig
[Git Source](https://github.com/Uniswap/v4-hooks/blob/924626d0c8f933c1c38d53555d77ded7e76f8009/src/interfaces/IStableStableHook.sol)

The fee configuration for each pool


```solidity
struct FeeConfig {
uint256 decayFactor;
uint256 optimalFeeSpread;
uint160 referenceSqrtPrice;
}
```

