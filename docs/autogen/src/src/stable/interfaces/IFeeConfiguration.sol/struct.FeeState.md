# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks/blob/9d55d934108997d23c71cbea024ed3fecf2b9d95/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 previousDecayingFeeE12; // Last decaying fee in 1e12 precision, or UNDEFINED_DECAYING_FEE_E12 if inside optimal range
uint160 previousSqrtAmmPriceX96; // AMM sqrt price at last swap; used to detect price movement direction
uint40 blockNumber; // Block when fee was last updated; determines decay based on blocks elapsed
}
```

