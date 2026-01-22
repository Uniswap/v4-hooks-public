# HistoricalFeeData
[Git Source](https://github.com/Uniswap/v4-hooks/blob/42f0f4c9ee15cb6b951d3e798fb2c00c2fd84420/src/types/HistoricalFeeData.sol)

The historical fee data for each pool


```solidity
struct HistoricalFeeData {
uint24 previousFee;
uint160 previousSqrtAmmPrice;
uint256 blockNumber;
}
```

