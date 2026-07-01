# MultiplexerHookData
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/MultiplexerTypes.sol)

**Title:**
MultiplexerTypes

**Author:**
Uniswap Labs

hookData encoding for the ALF multiplexer.

Callers encode hookData as `abi.encode(MultiplexerHookData(...))`.
The multiplexer supports two execution modes, selected implicitly:
**Autonomous mode** (all targets have amountSpecified = 0):
The multiplexer queries each target for an indicative quote, sorts by quote
quality, and executes a greedy split fill with price limits derived from each
candidate's pool state. Self-contained: no external planning required.
**Pre-planned mode** (any target has amountSpecified != 0):
The router has pre-computed the optimal split (e.g., using `swapToPrice` offchain).
The multiplexer executes targets in the given order with their specified amounts.
A target with amountSpecified = 0 receives whatever input/output remains.
Skips indicative queries and sorting: lower gas, router controls execution.
Both modes support tolerance enforcement via `strictTolerancePips` and forward
shared attestation data to the nested swaps.


```solidity
struct MultiplexerHookData {
bytes attestationData;
TargetedQuoter[] targets;
uint24 strictTolerancePips;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`attestationData`|`bytes`|Shared attestation payload forwarded to nested quoter swaps.|
|`targets`|`TargetedQuoter[]`|Targeted quoter list. Must be non-empty.|
|`strictTolerancePips`|`uint24`|Maximum relative deviation before revert, in parts per million (parts-per-million, not basis points: 10_000 pips = 1%). Set to 0 to disable strict tolerance checks.|

