# Liveness
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Liveness.sol)

**Title:**
Liveness

**Author:**
Uniswap Labs

Per-pool pause/resume flag for ALF quoter hooks, as a type-driven value. A pool defaults
to paused (`false`); the owner toggles it. Swap entry points gate on {requireLive}, and
the hook reports per-pool state via the consumer's `livePools` getter. The hook-level
`IALFHook.isLive()` is a separate, coarser signal and is unaffected by this type.

**Note:**
security-contact: security@uniswap.org


```solidity
struct Liveness {
mapping(PoolId poolId => bool) _inner;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`_inner`|`mapping(PoolId poolId => bool)`|Whether each pool is currently quoting and executing swaps.|

