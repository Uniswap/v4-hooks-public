# FeeConfig
[Git Source](https://github.com/Uniswap/v4-hooks/blob/831a6061131ddc01156ddc813ee65ad417011f7f/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeConfig {
uint256 k; // Decay rate per block; controls how fast fees decrease toward target. Stored in Q24 format.
uint256 logK; // Used for efficient decay calculation over many blocks
uint24 optimalFeeRateE6; // Optimal rate width in 1e6 precision; inside = consistent buy/sell prices, outside = flexible
uint160 referenceSqrtPriceX96; // Reference sqrt price; optimal rate centered around this
}
```

