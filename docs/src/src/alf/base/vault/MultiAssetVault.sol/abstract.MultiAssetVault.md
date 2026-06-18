# MultiAssetVault
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0c68c6912ec9b3df692fd62740997db52f245b7d/src/alf/base/vault/MultiAssetVault.sol)

**Inherits:**
BlockNumberish

**Title:**
MultiAssetVault

**Author:**
Uniswap Labs

Generic two-asset share-accounting primitive. Tracks proportional shares of an
abstract `(asset0, asset1)` pair indexed by an opaque `VaultId`.
Shares are non-transferable internal accounting -- there is no ERC-20 share
token. Each vault id has its own supply (`totalShares`) and per-user balance
(`userShares`). Conversion math uses the EIP-4626 virtual-shares pattern:
amount = shares * (total + 1) / (supply + 10**_decimalsOffset(vaultId))
The `+1` virtual asset and `+10**offset` virtual shares exist only in math --
they don't correspond to real entries and can never withdraw. They mitigate
post-bootstrap donation attacks: any direct donation to an underlying yield
source that the subclass reads through `_assetBalance` is captured
proportionally by the virtual position.
**Bootstrap drift.** The bootstrapper's economic claim on the pool's value is
`S / (S + 10**offset)` where `S = sqrt(received0 * received1)`. When `S` is
comparable to or smaller than `10**offset`, the bootstrapper PERMANENTLY loses
a meaningful fraction of their seed capital to the virtual position. With the
default `_decimalsOffset = 12`, drift breakpoints look like:
| Bootstrap (each side, 6dec)   | shares S | drift |
|-------------------------------|---------:|------:|
| 1 wei                         |     1    |   ~1  |
| 1 USDC (1e6 wei)              |    1e6   |   ~1  |
| 1k USDC (1e9 wei)             |    1e9   |  ~99% |
| 1M USDC (1e12 wei)            |    1e12  |   50% |
| 100M USDC (1e14 wei)          |    1e14  | 1ppm  |
| Bootstrap (each side, 18dec)  | shares S | drift |
| 1 wei                         |     1    |   ~1  |
| 1 token (1e18 wei)            |    1e18  | 1ppb  |
| 1k token (1e21 wei)           |    1e21  |  ~0   |
For ~ppm-or-better drift, operators MUST seed with `S >= 100 * 10**offset`.
The base enforces this floor at bootstrap with `BootstrapTooSmall`. Subclasses
that handle low-decimal pairs SHOULD override `_decimalsOffset(vaultId)` to
lower the offset (e.g., to 6 for stablecoin pairs).
Lifecycle:
- First deposit goes through `_bootstrap`, mints `sqrt(received0 * received1)`
shares all credited to the bootstrapper. The bootstrap amounts set the
initial share-asset ratio.
- Subsequent deposits / withdraws go through `_deposit` / `_withdraw`. Deposits
round UP (depositor pays slightly more); withdrawals round DOWN (withdrawer
receives slightly less). A configurable per-vault `_minDepositBlocks(vaultId)`
lock rejects withdrawals that arrive earlier than
`lastDepositBlock + _minDepositBlocks(vaultId)` (measured on the
`BlockNumberish` clock) to defend against atomic fee/yield sniping. The
default implementation returns `0`, which means NO lock -- same-block
deposit-then-withdraw is allowed. Subclasses that need the legacy same-block
ban override `_minDepositBlocks` to return `1`; values `> 1` enforce a
longer lock.
The base owns the share state, the share math, and the lifecycle. Subclasses
own asset I/O via three hooks:
- `_pullAsset(vaultId, asset, from, want) -> received`: pull tokens; return
actual received amount (FoT measurement is the subclass's responsibility).
- `_pushAsset(vaultId, asset, to, amount)`: push tokens to `to`; subclass is
free to source from raw balance, ERC-4626 vault, etc.
- `_assetBalance(vaultId, asset) -> uint256`: read total managed assets for
the (vault, asset) pair. The conversion math reads this for both legs.

This primitive is reentrancy-AGNOSTIC. Subclasses are responsible for guarding
their own external entry points (typically with `nonReentrant` plus a JIT-cycle
lock if applicable). The internal lifecycle is effects-first where possible:
share counters are updated before asset I/O so reentrant view paths see a
coherent snapshot.

**Note:**
security-contact: security@uniswap.org


## State Variables
### _assets

```solidity
mapping(VaultId vaultId => Assets) internal _assets
```


### _totalShares
Total shares outstanding for a vault, across all depositors. Real depositor
shares only; conversion math reads `supply + 10**_decimalsOffset()` to add
virtual shares for inflation defense. Subclasses expose typed getters (e.g.,
`PoolVault.totalShares(PoolId)`) over this internal storage.


```solidity
mapping(VaultId vaultId => uint256) internal _totalShares
```


### _userShares
Share balance for each (vaultId, user) pair. Numerator for a user's
proportional claim on vault assets.


```solidity
mapping(VaultId vaultId => mapping(address user => uint256)) internal _userShares
```


### _lastDepositBlock
Block number of the last `_deposit` for each (vaultId, user). `_withdraw`
reverts until `_getBlockNumberish() >= lastDepositBlock + _minDepositBlocks(vaultId)`,
defending against atomic fee/yield sniping. Read via `BlockNumberish` so the value
reflects the chain's fastest block clock; on Arbitrum One, `block.number` returns the
L1 block number which makes many sequencer transactions share the same value, which
would defeat the lock.


```solidity
mapping(VaultId vaultId => mapping(address user => uint256)) internal _lastDepositBlock
```


## Functions
### _bootstrap

Seed the vault with the first deposit. Mints `sqrt(received0 * received1)`
shares to `to` and sets the initial share/asset ratio. Caller is responsible
for authorization (typically owner-only on the consuming subclass).


```solidity
function _bootstrap(
    VaultId vaultId,
    address asset0,
    address asset1,
    address from,
    address to,
    uint256 amount0,
    uint256 amount1
) internal returns (uint256 sharesMinted);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`|The vault to bootstrap.|
|`asset0`|`address`| First asset address. Subclass-defined identifier used by `_pullAsset`.|
|`asset1`|`address`| Second asset address.|
|`from`|`address`|   The address to pull tokens from (passed to `_pullAsset`).|
|`to`|`address`|     The address to credit shares to.|
|`amount0`|`uint256`|Asset0 to deposit.|
|`amount1`|`uint256`|Asset1 to deposit.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sharesMinted`|`uint256`|Total shares minted, all credited to `to`.|


### _deposit

Mint `shares` to `to` by pulling proportional token amounts from `from`. The
conversion rounds UP per the virtual-offset formula -- depositor pays slightly
more to prevent share-value dilution. The asset pair is read from `_assets`
(set at bootstrap) so the caller can't accidentally pass a different pair.


```solidity
function _deposit(VaultId vaultId, address from, address to, uint256 shares)
    internal
    returns (uint256 amount0, uint256 amount1);
```

### _withdraw

Burn `shares` from `from` and send proportional token amounts to `to`. The
conversion rounds DOWN -- withdrawer receives slightly less to prevent
over-withdrawal at remaining shareholders' expense.


```solidity
function _withdraw(VaultId vaultId, address from, address to, uint256 shares)
    internal
    returns (uint256 amount0, uint256 amount1);
```

### _convertToAmounts

Convert a share amount to the equivalent token amounts for both assets,
proportional to the vault's current total balances. Uses the EIP-4626
virtual-offset formula:
amount = shares * (total + 1) / (supply + 10**_decimalsOffset())
Reverts if `supply == 0` -- pre-bootstrap vaults have no defined ratio.


```solidity
function _convertToAmounts(VaultId vaultId, address asset0, address asset1, uint256 shares, bool roundUp)
    internal
    view
    returns (uint256 amount0, uint256 amount1);
```

### _decimalsOffset

Number of "virtual shares" decimal places used in the inflation defense for a
specific vault. The conversion math reads `supply + 10**_decimalsOffset(vaultId)`
so an attacker's post-bootstrap donation is diluted across the virtual position.

Default: `12` for every vault (1e12 virtual shares). The relationship between
the offset and the bootstrapper's drift is approximately
`drift = 10**offset / (S + 10**offset)` where `S = sqrt(received0 * received1)`.
For ~ppm drift the offset SHOULD be 6-12 dB below `log10(S)`.
Subclasses MAY override per-vault — for example, a stablecoin-pair vault
(6-decimal tokens) might return `6` to keep drift below 1ppm at typical
operator bootstrap sizes, while keeping the default `12` for 18-decimal
pairs. The override SHOULD return a value bound to the bootstrap-time
pair (e.g., cached in the `Assets` struct or derived from
`IERC20Metadata.decimals()` lookups), so a single vault's offset is stable.


```solidity
function _decimalsOffset(VaultId vaultId) internal view virtual returns (uint8);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`|The vault to look up the offset for. Default impl ignores it.|


### _minDepositBlocks

Minimum number of `BlockNumberish`-clock blocks that must elapse between a
depositor's last `_deposit` and any subsequent `_withdraw` on the same vault.

Default: `0`, meaning NO lock -- the depositor may withdraw in the same block
as their deposit. This is a deliberate semantic: subclasses opt INTO a lock
(typically `1` to reproduce the legacy "same-block ban", or `N > 1` for a
longer hold) rather than the base imposing one. PoolVault overrides this to
read a per-pool storage value set at pool initialization.


```solidity
function _minDepositBlocks(VaultId vaultId) internal view virtual returns (uint64);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`|The vault to look up the lock for. Default impl ignores it.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint64`|blocks  Number of `BlockNumberish`-clock blocks the lock spans.|


### _pullAsset

Pull `want` of `asset` from `from` into the vault's custody, returning the
actual amount received. Subclasses are responsible for the transfer mechanism
(e.g., `IERC20.safeTransferFrom` + balance-delta measurement) and any
post-receipt routing (e.g., depositing to an ERC-4626 yield source). The
returned `received` is what the share math uses, so FoT/rebasing reconciliation
lives here.


```solidity
function _pullAsset(VaultId vaultId, address asset, address from, uint256 want)
    internal
    virtual
    returns (uint256 received);
```

### _pushAsset

Push `amount` of `asset` from the vault's custody to `to`. Subclasses are
responsible for sourcing the asset (raw balance, ERC-4626 withdrawal, claim
redemption, etc.) and the actual transfer.


```solidity
function _pushAsset(VaultId vaultId, address asset, address to, uint256 amount) internal virtual;
```

### _assetBalance

Read the vault's total managed balance of `asset`. Used by `_convertToAmounts`
for both legs. Subclasses sum whatever balance sources they manage (e.g.,
raw ERC-20 + ERC-6909 claims + ERC-4626 vault holdings).


```solidity
function _assetBalance(VaultId vaultId, address asset) internal view virtual returns (uint256);
```

## Events
### Bootstrap
Emitted on first deposit (bootstrap) -- sets the initial share/asset ratio.


```solidity
event Bootstrap(
    VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`| The vault being bootstrapped.|
|`provider`|`address`|The address that received the bootstrap shares.|
|`shares`|`uint256`|  Total shares minted (`sqrt(received0 * received1)`).|
|`amount0`|`uint256`| Asset0 transferred from the bootstrapper (post-FoT receipt).|
|`amount1`|`uint256`| Asset1 transferred from the bootstrapper (post-FoT receipt).|

### Deposit
Emitted when a depositor mints shares by providing proportional token amounts.


```solidity
event Deposit(VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`| The vault receiving the deposit.|
|`provider`|`address`|The address that received the minted shares.|
|`shares`|`uint256`|  Shares minted to `provider`.|
|`amount0`|`uint256`| Asset0 transferred from the depositor (post-FoT receipt).|
|`amount1`|`uint256`| Asset1 transferred from the depositor (post-FoT receipt).|

### Withdraw
Emitted when a depositor burns shares and receives proportional token amounts.


```solidity
event Withdraw(VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`| The vault being withdrawn from.|
|`provider`|`address`|The address whose shares were burned.|
|`shares`|`uint256`|  Shares burned from `provider`.|
|`amount0`|`uint256`| Asset0 transferred to the withdrawer.|
|`amount1`|`uint256`| Asset1 transferred to the withdrawer.|

## Errors
### InsufficientShares
The caller attempted to burn more shares than they hold.


```solidity
error InsufficientShares();
```

### VaultNotBootstrapped
`_deposit` was called before the vault was bootstrapped via `_bootstrap`.


```solidity
error VaultNotBootstrapped();
```

### VaultAlreadyBootstrapped
`_bootstrap` was called for a vault that already has shares.


```solidity
error VaultAlreadyBootstrapped();
```

### InsufficientBootstrap
Bootstrap amounts produce zero shares (one or both received amounts is zero).


```solidity
error InsufficientBootstrap();
```

### DepositLocked
`_withdraw` was called before the depositor's lock duration elapsed
(`_getBlockNumberish() < lastDepositBlock + _minDepositBlocks(vaultId)`).
Prevents atomic deposit-swap-withdraw fee/yield sniping.


```solidity
error DepositLocked(uint256 unlockBlock);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`unlockBlock`|`uint256`|The `BlockNumberish`-clock block at which the lock clears.|

### TransferReceiptShortfall
`_pullAsset` for a deposit/bootstrap delivered fewer tokens than requested
(typically a fee-on-transfer or rebasing token). The deposit path mints shares
against the requested amount, so accepting under-receipt would dilute existing
shareholders. Subclasses that want to support FoT/rebasing tokens must
compensate within `_pullAsset` (e.g., by topping up).


```solidity
error TransferReceiptShortfall();
```

### BootstrapTooSmall
Bootstrap shares (`sqrt(received0 * received1)`) are below the inflation-defense
floor of `100 * 10**_decimalsOffset(vaultId)`. Below this floor, the bootstrapper
PERMANENTLY loses more than ~1% of their seed capital to the virtual position.
Operators MUST seed with larger bootstrap amounts; the floor guarantees drift
stays below ~1%.


```solidity
error BootstrapTooSmall(uint256 sharesMinted, uint256 minShares);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sharesMinted`|`uint256`|The bootstrap shares the operator's amounts would have produced.|
|`minShares`|`uint256`|   The minimum shares the offset requires (`100 * 10**offset`).|

## Structs
### Assets
Asset pair backing each vault, set at first bootstrap. Immutable thereafter --
`_bootstrap` reverts on a re-bootstrap, so the pair never changes once set.


```solidity
struct Assets {
    address asset0;
    address asset1;
}
```

