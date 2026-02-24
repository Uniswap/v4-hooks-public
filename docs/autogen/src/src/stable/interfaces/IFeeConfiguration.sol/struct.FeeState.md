# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/74df6e89f451dbe08013baeb03026527017e9ada/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 decayingFeeE12; // Decaying fee in 1e12 precision, or UNDEFINED_DECAYING_FEE_E12 if inside optimal range
uint160 sqrtAmmPriceX96; // AMM sqrt price at the start of the current block; used as cached price for same-block swaps and cross-block price movement detection
uint40 blockNumber; // used to detect same-block swaps and compute elapsed blocks for decay
}
```

