# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/5e63e895edc167b0559892021e6a254cfe271a5a/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 decayingFeeE12; // Decaying fee in 1e12 precision, or UNDEFINED_DECAYING_FEE_E12 if inside optimal range
uint160 sqrtAmmPriceX96; // AMM sqrt price at the start of the most recently swapped block; used as cached price for same-block swaps and cross-block price movement detection (0 when the pool is initialized or reset)
uint40 blockNumber; // Block number of the most recent swap (0 when the pool is initialized or reset); used to detect same-block swaps and compute blocks elapsed for decay
}
```

