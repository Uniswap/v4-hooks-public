# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/f7e200503087429d345c3d32394db9555f4d7b50/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 decayingFeeE12; // Decaying fee in 1e12 precision, or UNDEFINED_DECAYING_FEE_E12 if inside optimal range
uint160 sqrtAmmPriceX96; // AMM sqrt price; used to detect price movement direction
uint40 blockNumber; // Block when the swap occurred; used to determine decay based on blocks elapsed
}
```

