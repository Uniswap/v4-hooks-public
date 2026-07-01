# Inventory
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

**Title:**
Inventory

**Author:**
Uniswap Labs

Rehypothecation + claim-accounting capability for ALF hooks, as a type-driven value.
Tracks three asset sources per opaque `bytes32 bucket`:
1. ERC-4626 vault shares: assets rehypothecated into yield-bearing vaults between
swaps, isolated per bucket so deployments sharing a vault contract cannot consume
each other's shares.
2. ERC-6909 claims: deferred-settlement credits minted on the PoolManager when a
positive hook delta cannot yet be `take`n; redeemed via `InventoryLib.redeemClaims`.
3. Raw ERC-20: tokens held directly by the consuming contract, attributed per bucket.
The source of truth for ownership; the contract's global `balanceOf` is never read
for accounting decisions.
## Type-driven composition
The consumer holds an `Inventory` as a plain storage field and calls behavior on it
directly, as `_inventory.assetBalance(bucket)`. The pure, context-free operations
(accessors, balance views, claim accounting) live here as file-level free functions
bound `using { ... } for Inventory global`. The operations
that move tokens, and so need the consumer's execution context (`address(this)` for
vault `deposit`/`withdraw`/`redeem`, PoolManager `take`/`burn`, allowance checks), live
in `InventoryLib`, a library whose internal functions inline into the consumer so
`this` resolves correctly. Both are invoked uniformly as `_inventory.method(...)`.
## Bucket key
`bucket` is opaque and consumer-defined: the accounting partition, distinct from the
asset (`currency`). `PoolVault` uses `keccak256(poolId, currency)`; a token-keyed
consumer uses `bytes32(uint256(uint160(token)))`. Functions that touch tokens take
`currency` separately because the bucket alone does not name the underlying asset.
## Compatibility
Vault interaction is via the ERC-4626 interface only and deliberately avoids
`maxWithdraw` on hot paths (curated/gated vaults like Morpho VaultV2 can return `0`);
{effectiveBalance} sizes via `previewRedeem`. Fee-on-entry/exit vaults are rejected by
`InventoryLib.requireFeelessVault`; fee-on-transfer / rebasing underlyings are not
supported.

**Note:**
security-contact: security@uniswap.org


```solidity
struct Inventory {
mapping(bytes32 bucket => IERC4626 vault) vault;
mapping(bytes32 bucket => uint256 shares) vaultShares;
mapping(bytes32 bucket => CurrencyState) state;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`vault`|`mapping(bytes32 bucket => IERC4626 vault)`|      The ERC-4626 vault bound to a bucket (`address(0)` = hold as raw ERC-20).|
|`vaultShares`|`mapping(bytes32 bucket => uint256 shares)`|The number of vault shares the bucket owns.|
|`state`|`mapping(bytes32 bucket => CurrencyState)`|      The bucket's packed raw ERC-20 + ERC-6909 claim balances.|

