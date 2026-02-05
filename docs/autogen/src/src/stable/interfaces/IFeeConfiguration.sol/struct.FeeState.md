# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks/blob/ed81fe2a4a0d3051e856ceb7db85c49785fdfa56/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 previousFeeE12; // Last flexible fee in 1e12 precision, or UNDEFINED_FLEXIBLE_FEE_E12 if inside optimal range
uint160 previousSqrtAmmPriceX96; // AMM sqrt price at last swap; used to detect price movement direction
uint40 blockNumber; // Block when fee was last updated; determines decay based on blocks elapsed
}
```

