# VaultId
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0a317c27dcab11b55acb839bccd006c6ffa8744c/src/alf/types/VaultId.sol)

**Title:**
VaultId

**Author:**
Uniswap Labs

User-defined value type identifying a vault within a `MultiAssetVault` deployment.
32-byte opaque key; equality is identity. Subclass conventions determine how
the key is derived (e.g., PoolVault uses `PoolId.unwrap(key.toId())`; a generic
deployer might use `keccak256(abi.encode(asset0, asset1, salt))`).

Type-safe wrapper around `bytes32` so callers can't accidentally pass a random
hash where a vault key is expected. Pure value type -- no storage, no methods
beyond equality and conversion via `wrap`/`unwrap`.


```solidity
type VaultId is bytes32
```

