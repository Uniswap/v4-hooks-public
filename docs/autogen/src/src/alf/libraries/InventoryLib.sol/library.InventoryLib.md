# InventoryLib
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/libraries/InventoryLib.sol)

**Title:**
InventoryLib

**Author:**
Uniswap Labs

The token-custody half of the `Inventory` capability: the operations that move tokens
and therefore need the consuming contract's execution context. Internal library
functions inline into the consumer, so `address(this)` (the token custodian), vault
`deposit`/`withdraw`/`redeem`, PoolManager `take`/`burn`, and allowance checks all
resolve against the consumer. The pure, context-free `Inventory` operations
(accessors, balance views, claim accounting) are file-level free functions in
`types/Inventory.sol`; a consumer binds this library with `using InventoryLib for
Inventory` so both halves are invoked uniformly as `_inventory.method(...)`.

The vault-fee guards' errors ([VaultChargesEntryFee](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#vaultchargesentryfee)/[VaultChargesExitFee](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#vaultchargesexitfee)) live here so
callers that match on them keep a stable qualified reference.

**Note:**
security-contact: security@uniswap.org


## Functions
### depositToVault

Deposit `amount` of `currency` (already held by the consumer) into `bucket`'s
vault, or credit raw ERC-20 if no vault is bound.

LP-path semantics: a vault rejection bubbles up to the caller (no try/catch). Reverts
[ZeroSharesMinted](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#zerosharesminted) if a non-zero deposit mints no shares.


```solidity
function depositToVault(Inventory storage self, bytes32 bucket, Currency currency, uint256 amount) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|    Capability storage.|
|`bucket`|`bytes32`|  The accounting partition to credit.|
|`currency`|`Currency`|The underlying asset being deposited.|
|`amount`|`uint256`|  The asset amount to deposit (token's native decimals).|


### tryDepositAll

Best-effort deposit of the bucket's tracked raw ERC-20 into its vault.

No-ops (no vault / zero raw) return `ok = true`. The vault-deposit failure is caught; a
successful-but-zero-share deposit still reverts [ZeroSharesMinted](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#zerosharesminted). When `ok` is false
and `amount > 0` the consumer SHOULD emit its own deposit-skipped event with `reason`.


```solidity
function tryDepositAll(Inventory storage self, bytes32 bucket)
    internal
    returns (uint256 amount, bool ok, bytes memory reason);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition whose raw balance to sweep.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|The raw amount the deposit attempted (token's native decimals).|
|`ok`|`bool`|    True if the deposit succeeded or was a no-op; false if the vault reverted.|
|`reason`|`bytes`|The raw revert data from `vault.deposit` when `ok` is false; empty otherwise.|


### withdrawFromVault

Withdraw `amount` of the bucket's vaulted assets back to raw ERC-20, optimistically.

No-op if no vault is bound. A vault revert bubbles up to the caller.
[CrossPoolShareLeak](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#crosspoolshareleak) guards against a vault consuming more shares than the bucket owns.


```solidity
function withdrawFromVault(Inventory storage self, bytes32 bucket, uint256 amount) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to withdraw for.|
|`amount`|`uint256`|The asset amount to pull from the vault (token's native decimals).|


### tryDrain

Best-effort full redemption of the bucket's vault position back to raw ERC-20.

`shares == 0` means nothing to drain (the consumer emits no event); otherwise `ok` true
⇒ consumer emits drained(shares, assets), false ⇒ consumer emits
drain-skipped(shares, reason). Redeems exactly the bucket's own shares, preserving
cross-bucket isolation.


```solidity
function tryDrain(Inventory storage self, bytes32 bucket)
    internal
    returns (uint256 shares, uint256 assets, bool ok, bytes memory reason);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to drain.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`shares`|`uint256`|The vault shares the drain operated on (`0` if nothing to drain).|
|`assets`|`uint256`|The asset amount received and credited to raw ERC-20 on success.|
|`ok`|`bool`|    True if the redeem succeeded; false if the vault reverted.|
|`reason`|`bytes`|The raw revert data from `vault.redeem` when `ok` is false; empty otherwise.|


### ensureERC20

Ensure the bucket's raw ERC-20 holds at least `amount`, withdrawing the shortfall
from the vault, then debit it.

For a non-vaulted bucket with insufficient raw, the `bal - amount` subtraction panics
on underflow (no sentinel). [CrossPoolShareLeak](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#crosspoolshareleak) guards the vaulted path.

On the vaulted-shortfall path the bucket is set to `0` rather than computed: it
withdraws exactly `shortfall = amount - bal`, so after crediting the withdrawal and
debiting `amount` the bucket nets to zero (`bal + shortfall == amount`). Do not
"fix" this into an arithmetic expression; the literal zero is the correct result.


```solidity
function ensureERC20(Inventory storage self, bytes32 bucket, uint256 amount) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to debit.|
|`amount`|`uint256`|The asset amount to make available and debit (token's native decimals).|


### redeemClaims

Redeem the bucket's ERC-6909 claims to raw ERC-20 via `pm` (only inside an unlock).

Caps the physical `take` at the PoolManager's current balance, since claims minted by
an earlier same-bucket swap in the same unsettled tx are not yet backed, and retains
any unbacked remainder as claims.


```solidity
function redeemClaims(Inventory storage self, bytes32 bucket, Currency currency, IPoolManager pm)
    internal
    returns (uint256 erc20Bal);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|    Capability storage.|
|`bucket`|`bytes32`|  The accounting partition whose claims to redeem.|
|`currency`|`Currency`|The underlying asset of the claims.|
|`pm`|`IPoolManager`|      The v4 PoolManager to burn the ERC-6909 claims on and `take` from.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`erc20Bal`|`uint256`|The bucket's raw ERC-20 balance after redemption (token's native decimals).|


### approveVault

Grant max allowance to `vault` for `currency` (idempotent).

`forceApprove` zeros first for USDT-style tokens. Consumers call once per
(currency, vault) at bind. No-op for `address(0)` vault.


```solidity
function approveVault(Currency currency, address vault) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`currency`|`Currency`|The underlying asset to approve.|
|`vault`|`address`|   The ERC-4626 vault to grant allowance to.|


### revokeVaultApproval

Zero the consumer's standing approval to `vault`. The emergency counterpart to
[approveVault](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#approvevault).

Caller MUST also stop deposits, or the LP path re-arms it via [ensureVaultAllowance](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#ensurevaultallowance).
No-op for `address(0)` vault.


```solidity
function revokeVaultApproval(Currency currency, address vault) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`currency`|`Currency`|The underlying asset whose approval to revoke.|
|`vault`|`address`|   The ERC-4626 vault to revoke allowance from.|


### ensureVaultAllowance

Refresh allowance to `>= amount` (recovery for USDT-style tokens whose max
allowance is decremented on transfer).

No-op for the common non-decrementing case.


```solidity
function ensureVaultAllowance(Currency currency, address vault, uint256 amount) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`currency`|`Currency`|The underlying asset to approve.|
|`vault`|`address`|   The ERC-4626 vault to grant allowance to.|
|`amount`|`uint256`|  The minimum allowance required for the current operation (native decimals).|


### requireFeelessVault

Reject ERC-4626 vaults that apply entry or exit fees.

Leverages the EIP-4626 rule that `convertTo*` MUST NOT factor fees while `preview*`
MUST. No-op for an unset vault. Catches honest fee disclosures only (see PoolVault
`Vault Compatibility` for the adversarial-vault socialization that remains). Reverts
[VaultChargesEntryFee](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#vaultchargesentryfee) / [VaultChargesExitFee](/src/alf/libraries/InventoryLib.sol/library.InventoryLib.md#vaultchargesexitfee) on divergence.


```solidity
function requireFeelessVault(IERC4626 vault) internal view;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vault`|`IERC4626`|The ERC-4626 vault to probe.|


## Errors
### CrossPoolShareLeak
A vault redemption returned more shares than the bucket owns. Defensive; should
never trigger if `vaultShares` accounting is consistent.


```solidity
error CrossPoolShareLeak();
```

### ZeroSharesMinted
`vault.deposit` returned zero shares for a non-zero asset deposit. Reverting fail-fast
prevents asset loss into a vault that gives no claim back.


```solidity
error ZeroSharesMinted();
```

### VaultChargesEntryFee
The configured ERC-4626 vault applies an entry fee (`previewDeposit < convertToShares`).


```solidity
error VaultChargesEntryFee();
```

### VaultChargesExitFee
The configured ERC-4626 vault applies an exit fee (`previewRedeem < convertToAssets`).


```solidity
error VaultChargesExitFee();
```

