# TargetedQuoter
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/MultiplexerTypes.sol)

A specific quoter target for the multiplexer.

`amountSpecified` controls how much flow this quoter handles:
- 0: autonomous mode, the multiplexer decides (fills remaining with price limits)
- negative: exact input amount for this quoter (e.g., -600e18 = spend 600 tokens here)
- positive: exact output amount from this quoter (e.g., 400e18 = get 400 tokens here)
The sign convention matches SwapParams.amountSpecified.


```solidity
struct TargetedQuoter {
PoolKey poolKey;
int256 amountSpecified;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|The quoter's pool key (hook address embedded in `poolKey.hooks`).|
|`amountSpecified`|`int256`|Pre-planned amount for this quoter. Zero lets the multiplexer decide the amount or fill the remaining amount.|

