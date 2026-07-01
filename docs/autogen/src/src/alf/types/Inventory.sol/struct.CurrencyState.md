# CurrencyState
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

Packed per-bucket ERC-20 + ERC-6909 claim balance.

Co-located in one 32-byte slot so the pair-aware paths read both with a single SLOAD.
`uint128` per field dwarfs any plausible per-bucket amount; writes SafeCast.


```solidity
struct CurrencyState {
uint128 erc20;
uint128 claims;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`erc20`|`uint128`| Raw ERC-20 tokens (in the token's native decimals) attributed to the bucket.|
|`claims`|`uint128`|ERC-6909 claims on the PoolManager (token's native decimals) for the bucket.|

