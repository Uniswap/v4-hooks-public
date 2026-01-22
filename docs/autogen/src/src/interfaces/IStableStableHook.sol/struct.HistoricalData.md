# HistoricalData
[Git Source](https://github.com/Uniswap/v4-hooks/blob/924626d0c8f933c1c38d53555d77ded7e76f8009/src/interfaces/IStableStableHook.sol)

The historical data for each pool


```solidity
struct HistoricalData {
uint24 previousFee;
uint160 previousSqrtAmmPrice;
uint256 blockNumber;
}
```

