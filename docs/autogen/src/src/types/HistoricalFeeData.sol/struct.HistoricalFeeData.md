# HistoricalFeeData
[Git Source](https://github.com/Uniswap/v4-hooks/blob/cc39bad2f9286aefd0824c4bc93d241fe8657275/src/types/HistoricalFeeData.sol)

The historical fee data for each pool


```solidity
struct HistoricalFeeData {
uint24 previousFee;
uint160 previousSqrtAmmPriceX96;
uint256 blockNumber;
}
```

