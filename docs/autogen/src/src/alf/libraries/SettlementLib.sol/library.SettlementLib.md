# SettlementLib
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/libraries/SettlementLib.sol)

**Title:**
SettlementLib

**Author:**
Uniswap Labs

Single net-delta settlement authority for ALF hooks that custody an `Inventory`.
Under v4 flash accounting every currency delta must net to zero before an `unlock`
finalizes, so only one actor may call `settle`, `take`, `mint`, or `burn` for delta
resolution. That actor is this library. Composed capabilities do not settle
themselves: they mutate their `Inventory` bucket (deposit, withdraw, fee skim), and
[resolveCurrency](/src/alf/libraries/SettlementLib.sol/library.SettlementLib.md#resolvecurrency) settles or parks the resulting net delta once per currency.
Routing all resolution through one function lets several fund-touching capabilities
share a hook. Each records its effect as a bucket adjustment, and a single resolve
nets the combined position, so no two capabilities write the same `currencyDelta`.
## Resolution
For each currency, after the cycle's operations complete:
- negative delta (hook owes the PoolManager): settle from the hook's raw balance
(sync, transfer, settle; or `settle{value}` for native ETH) and debit the bucket's
raw ledger.
- positive delta (PoolManager owes the hook): the swapper has not settled yet, so
mint ERC-6909 claims rather than calling `take`, and record them on the bucket.
The claims redeem to raw on the next cycle via `InventoryLib.redeemClaims`.
Internal library functions inline into the consumer, so `address(this)` and token
custody resolve to the consuming hook. The `Inventory` is passed by storage reference
from the field the consumer holds.

**Note:**
security-contact: security@uniswap.org


## Functions
### resolveCurrency

Resolve the hook's net delta for a single `currency` against an `Inventory` bucket:
settle a debit from the bucket's raw balance, or mint claims for a credit.

MUST be called inside the v4 unlock once the cycle's operations are complete, and is
the ONLY delta-resolution path that touches `settle` / `mint`. A negative delta settles
`owed` of the hook's raw balance and debits the bucket (reverts
`InsufficientPoolBalance` if the bucket's raw ledger is short). A positive delta mints
ERC-6909 claims (rather than `take`, since the swapper's input is not yet settled) and
records them on the bucket.

`delta == 0` is a no-op: neither branch is taken, nothing is owed in either direction,
and the bucket is left untouched.


```solidity
function resolveCurrency(Inventory storage inventory, IPoolManager poolManager, bytes32 bucket, Currency currency)
    internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`inventory`|`Inventory`|  The consumer's `Inventory` storage; the bucket's raw ledger and claim counter are updated here.|
|`poolManager`|`IPoolManager`|The v4 PoolManager to settle against.|
|`bucket`|`bytes32`|     The `Inventory` accounting partition backing this (pool, currency).|
|`currency`|`Currency`|   The currency whose net delta to resolve.|


