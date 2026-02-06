# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks/blob/d85a4c0f234196b046ed00df089e0e78e98074ef/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 previousFeeE12; // Last decaying fee in 1e12 precision, or UNDEFINED_DECAYING_FEE_E12 if inside optimal range
uint160 previousSqrtAmmPriceX96; // AMM sqrt price at last swap; used to detect price movement direction
uint40 blockNumber; // Block when fee was last updated; determines decay based on blocks elapsed
}
```

