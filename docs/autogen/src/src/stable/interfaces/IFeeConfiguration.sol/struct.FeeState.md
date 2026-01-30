# FeeState
[Git Source](https://github.com/Uniswap/v4-hooks/blob/f1e6f575bfe1e9a74ff4f8105848ddf85efaaa12/src/stable/interfaces/IFeeConfiguration.sol)


```solidity
struct FeeState {
uint40 previousFee; // Last flexible fee charged in 1e12 precision; used for exponential decay calculation
uint160 previousSqrtAmmPriceX96; // AMM sqrt price at last swap; used to detect price movement direction
uint256 blockNumber; // Block when fee was last updated; determines decay based on blocks elapsed
}
```

