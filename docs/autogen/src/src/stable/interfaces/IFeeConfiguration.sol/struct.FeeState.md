# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/d865a63c111824f657d4204c5a03eb9e43a7ea02/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 decayingFeeE12; // Decaying fee in 1e12 precision, or UNDEFINED_DECAYING_FEE_E12 if inside optimal range
uint160 sqrtAmmPriceX96; // AMM sqrt price at the start of the most recently swapped block; used as cached price for same-block swaps and cross-block price movement detection
uint40 blockNumber; // Block number of the most recent swap; used to detect same-block swaps and compute blocks elapsed for decay
}
```

