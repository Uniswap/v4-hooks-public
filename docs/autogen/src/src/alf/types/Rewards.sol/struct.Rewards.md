# Rewards
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

**Title:**
Rewards

**Author:**
Uniswap Labs

Liquidity-incentives capability: Synthetix-style per-share reward accrual keyed by an
opaque `VaultId`, decoupled from where the share balances live. A hook that already
tracks LP shares (e.g. via a `Shares` ledger) composes this as a plain storage field
and:
1. calls {checkpoint} from `PoolVault._onShareCheckpoint`, which fires
immediately before every share mutation with the pre-mutation total and user
balances, and
2. exposes owner funding ({notifyRewardAmount}) plus a user {claim} entry point.
Accrual follows the canonical Synthetix `StakingRewards` math, with the clock changed
from wall-time to block height: a global `rewardPerTokenStored` index accumulates
`rewardRate` per block spread across the total share supply, and each account is
credited `balance * (index - paidIndex)` at every checkpoint. The caller supplies both
the share balances and the current block at checkpoint time (the type owns neither), so
the same type works over any share ledger and any `BlockNumberish` consumer.
The checkpoint fires only on share mutations (bootstrap, deposit, withdraw), not on
swaps, so accrual adds no swap-path gas.
The consumer holds a `Rewards` storage field and calls these free functions on it
directly, as `rewards.checkpoint(...)`. The reward token, period, and per-user
accounting are isolated per `VaultId`.

**Note:**
security-contact: security@uniswap.org


```solidity
struct Rewards {
mapping(VaultId vaultId => Reward) _inner;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`_inner`|`mapping(VaultId vaultId => Reward)`|The per-`VaultId` reward program state.|

