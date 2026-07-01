# DepositGate
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/DepositGate.sol)

**Title:**
DepositGate

**Author:**
Uniswap Labs

Per-pool gate for whether non-owner addresses may deposit, as a type-driven value. The
gate is set at pool initialization and toggled by the owner thereafter. The consumer
combines {isOpen} with its own owner check to authorize a deposit (the owner can always
deposit; non-owners only when the gate is open), and re-exposes per-pool state through
its `externalDepositsEnabled` getter.

**Note:**
security-contact: security@uniswap.org


```solidity
struct DepositGate {
mapping(PoolId poolId => bool) _inner;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`_inner`|`mapping(PoolId poolId => bool)`|Whether each pool permits non-owner deposits.|

