# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks/blob/8fe1b2a4383ba7acecad71ba23c30b82aa8680d9/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 previousFeeE12; // Last decaying fee in 1e12 precision, or UNDEFINED_DECAYING_FEE_E12 if inside optimal range
uint160 previousSqrtAmmPriceX96; // AMM sqrt price at last swap; used to detect price movement direction
uint40 blockNumber; // Block when fee was last updated; determines decay based on blocks elapsed
}
```

