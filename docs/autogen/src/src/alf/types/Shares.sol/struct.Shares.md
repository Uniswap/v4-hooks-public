# Shares
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

**Title:**
Shares

**Author:**
Uniswap Labs

Two-asset proportional share ledger as a type-driven value. Tracks non-transferable
shares of an abstract `(asset0, asset1)` pair indexed by an opaque `VaultId`: there is
no ERC-20 share token, only internal accounting. A consumer holds a `Shares` storage
field and drives it through the free functions below; the consumer owns the lifecycle
(asset I/O, accrual checkpoints, the block clock, and the per-vault offset/lock config),
while this type owns the ledger state, the conversion math, and the ledger invariants.
## Inflation defense
Conversion uses the EIP-4626 virtual-shares pattern:
amount = shares * (total + 1) / (supply + 10**offset)
The `+1` virtual asset per side and `+10**offset` virtual shares exist only in the math;
they hold no real entry and can never withdraw. They mitigate post-bootstrap donation
attacks: a direct donation to any balance source the consumer reports through the
conversion's `bal0`/`bal1` inputs is captured proportionally by the virtual position,
making such attacks uneconomic regardless of bootstrap size.
## Bootstrap drift
The bootstrapper's economic claim is `S / (S + 10**offset)` where
`S = sqrt(received0 * received1)`. When `S` is comparable to or smaller than
`10**offset`, the bootstrapper permanently loses a meaningful fraction of their seed to
the virtual position. With `offset = 12`:
| Bootstrap (each side, 6dec)  | shares S | drift |
|------------------------------|---------:|------:|
| 1 USDC (1e6 wei)             |    1e6   |   ~1  |
| 1k USDC (1e9 wei)            |    1e9   |  ~99% |
| 1M USDC (1e12 wei)           |    1e12  |   50% |
| 100M USDC (1e14 wei)         |    1e14  | 1ppm  |
| Bootstrap (each side, 18dec) | shares S | drift |
| 1 token (1e18 wei)           |    1e18  | 1ppb  |
| 1k token (1e21 wei)          |    1e21  |  ~0   |
For ~ppm-or-better drift, operators MUST seed with `S >= 100 * 10**offset`. The
{creditBootstrap} caller enforces this floor with {BootstrapTooSmall}. Consumers serving
low-decimal pairs SHOULD lower the offset they pass to {convertToAmounts} and the floor
(e.g. 6 for stablecoin pairs).

This type is reentrancy-agnostic and makes no external calls: every function is pure
ledger math over storage. The consumer guards its own entry points and orders the
lifecycle effects-first (mutating share counters before asset I/O) so a reentrant view
path observes a coherent snapshot.

**Note:**
security-contact: security@uniswap.org


```solidity
struct Shares {
mapping(VaultId vaultId => Assets) assets;
mapping(VaultId vaultId => uint256) totalShares;
mapping(VaultId vaultId => mapping(address user => uint256)) userShares;
mapping(VaultId vaultId => mapping(address user => uint256)) lastDepositBlock;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`assets`|`mapping(VaultId vaultId => Assets)`|         The bootstrap-bound asset pair per vault.|
|`totalShares`|`mapping(VaultId vaultId => uint256)`|    Real shares outstanding per vault. Conversion adds virtual shares on top.|
|`userShares`|`mapping(VaultId vaultId => mapping(address user => uint256))`|     Real shares per `(vault, user)`. Numerator of a user's proportional claim.|
|`lastDepositBlock`|`mapping(VaultId vaultId => mapping(address user => uint256))`|Block of the last deposit per `(vault, user)`, on the consumer's clock.|

