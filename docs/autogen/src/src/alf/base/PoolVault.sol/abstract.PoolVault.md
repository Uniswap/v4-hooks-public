# PoolVault
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0a317c27dcab11b55acb839bccd006c6ffa8744c/src/alf/base/PoolVault.sol)

**Inherits:**
[MultiAssetVault](/src/alf/base/vault/MultiAssetVault.sol/abstract.MultiAssetVault.md)

**Title:**
PoolVault

**Author:**
Uniswap Labs

Uniswap v4 hook adapter over `MultiAssetVault`. Adds the V4-specific concerns:
ERC-4626 vault rehypothecation, ERC-6909 PoolManager claim handling, and per-pool
tracking of raw ERC-20 attributed to the hook contract.
`MultiAssetVault` provides the share accounting, virtual-shares inflation defense,
and bootstrap/deposit/withdraw lifecycle. PoolVault overrides the three asset-I/O
hooks (`_pullAsset`, `_pushAsset`, `_assetBalance`) to plumb V4 currency types and
vault rehypothecation, and exposes `PoolKey`-flavored entry points so subclasses
(e.g., SmartPoolHook) integrate naturally.
For every `(PoolId, Currency)`, PoolVault tracks three asset sources:
1. **ERC4626 vault shares** -- assets rehypothecated into yield-bearing vaults
between swaps. Tracked per-pool via `_vaultShares` to isolate multi-pool
deployments that share the same vault contract.
2. **ERC-6909 claims** -- deferred settlement tokens minted on the PoolManager
when afterSwap produces a positive delta but the PM lacks ERC-20 (because the
swapper hasn't settled yet). Tracked per-pool via `_state.claims` and redeemed
in the next `_redeemPoolClaims`.
3. **Raw ERC-20** -- tokens held directly by the hook, attributed per-pool via
`_state.erc20`. Source of truth for pool ownership; the hook's global
`balanceOf` is never read for accounting decisions.
## Token Compatibility
Inbound transfers (user → hook) use OZ `SafeERC20.safeTransferFrom`. Outbound
(hook → user) uses v4-core's `Currency.transfer`. Vault approvals use
`forceApprove` for tokens that require zero-out-first.
**Native ETH is NOT supported** -- subclasses must reject `address(0)` currencies
at pool initialization. PoolVault calls `IERC20.safeTransferFrom(address(0), ...)`
which would revert; the subclass-level rejection makes the failure mode explicit
at init.

See `MultiAssetVault` for the share-math + lifecycle. This contract is the V4
binding: it translates `PoolKey` / `PoolId` / `Currency` into the base's
`VaultId` / `address asset` plumbing, and adds the V4-specific helpers
(`_redeemPoolClaims`, `_recordClaims`, `_debitPoolERC20`) that the JIT lifecycle
in subclasses calls during swap callbacks.

**Note:**
security-contact: security@uniswap.org


## State Variables
### vaults
ERC4626 vault for each (pool, currency) pair.

`address(0)` means no vault is configured -- tokens are held as ERC-20 in the
hook and tracked via `_state.erc20`. Vaults are typically set at pool
initialization and are immutable for the pool's lifetime.


```solidity
mapping(PoolId => mapping(Currency => IERC4626)) public vaults
```


### _vaultShares
Number of ERC4626 vault shares this pool owns. Isolated from other pools that
may use the same vault contract, preventing one pool from consuming another's
shares.


```solidity
mapping(PoolId => mapping(Currency => uint256)) internal _vaultShares
```


### _state
Packed per-(pool, currency) ERC-20 + ERC-6909 claim state.
`state.erc20`  -- ERC-20 tokens held by the hook attributed to this pool.
ALWAYS reflects the per-pool share of the hook's global token
balance -- never substitutes a global `balanceOf` read.
`state.claims` -- ERC-6909 claims on the PoolManager attributed to this pool.
Minted when afterSwap produces a positive hook delta; redeemed
to ERC-20 in the next beforeSwap via `_redeemPoolClaims`.


```solidity
mapping(PoolId => mapping(Currency => CurrencyState)) internal _state
```


## Functions
### totalShares

Total shares outstanding for a pool, across all depositors.


```solidity
function totalShares(PoolId poolId) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose share supply should be read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|shares Total non-transferable pool shares outstanding.|


### userShares

Share balance for `(poolId, user)`.


```solidity
function userShares(PoolId poolId, address user) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose share ledger should be read.|
|`user`|`address`|The account whose share balance should be read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|shares Non-transferable pool shares held by `user`.|


### totalAssets

Returns the total managed assets for a pool across both currencies. Sums
vault assets (via `convertToAssets`), ERC-6909 claims, and per-pool ERC-20.


```solidity
function totalAssets(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The PoolKey identifying the pool and its two currencies.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|Total managed currency0 assets, in currency0 native decimals.|
|`amount1`|`uint256`|Total managed currency1 assets, in currency1 native decimals.|


### previewDeposit

Preview the token amounts required to mint `shares` for a pool. Rounds up.


```solidity
function previewDeposit(PoolKey calldata key, uint256 shares)
    external
    view
    returns (uint256 amount0, uint256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The PoolKey identifying the pool and its two currencies.|
|`shares`|`uint256`|The number of non-transferable pool shares to mint.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|Required currency0 amount, rounded up, in currency0 native decimals.|
|`amount1`|`uint256`|Required currency1 amount, rounded up, in currency1 native decimals.|


### previewWithdraw

Preview the token amounts returned for burning `shares` from a pool. Rounds down.


```solidity
function previewWithdraw(PoolKey calldata key, uint256 shares)
    external
    view
    returns (uint256 amount0, uint256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The PoolKey identifying the pool and its two currencies.|
|`shares`|`uint256`|The number of non-transferable pool shares to burn.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|Returned currency0 amount, rounded down, in currency0 native decimals.|
|`amount1`|`uint256`|Returned currency1 amount, rounded down, in currency1 native decimals.|


### _vaultIdFor

Wrap a `PoolId` into the base's `VaultId` namespace. Info-lossless cast
through bytes32; both types are `type X is bytes32`.


```solidity
function _vaultIdFor(PoolId poolId) internal pure returns (VaultId);
```

### _bootstrap

See {MultiAssetVault._bootstrap}. Adapter over PoolKey/Currency.


```solidity
function _bootstrap(PoolKey calldata key, address from, address to, uint256 amount0, uint256 amount1)
    internal
    returns (uint256 sharesMinted);
```

### _deposit

See {MultiAssetVault._deposit}. Asset pair is read from the base's `_assets`
storage (set at bootstrap), not threaded through here.


```solidity
function _deposit(PoolKey calldata key, address from, address to, uint256 shares)
    internal
    returns (uint256 amount0, uint256 amount1);
```

### _withdraw

See {MultiAssetVault._withdraw}.


```solidity
function _withdraw(PoolKey calldata key, address from, address to, uint256 shares)
    internal
    returns (uint256 amount0, uint256 amount1);
```

### _totalAssets

Total managed assets for a pool across both currencies.


```solidity
function _totalAssets(PoolKey memory key) internal view returns (uint256 amount0, uint256 amount1);
```

### _assetBalanceV4

Total managed balance for a single (pool, currency) pair. Sums three sources:
ERC4626 vault assets (via `convertToAssets`), ERC-6909 claims, and per-pool
ERC-20 holdings.
DELIBERATE CAP-ASYMMETRY (do NOT "fix"): this function does NOT cap the vault
contribution by `maxWithdraw`, while `_effectiveBalance` does. The asymmetry
is load-bearing for share math — LP shares represent the pool's TOTAL economic
claim, including capital temporarily locked in a paused, capped, or
utilization-constrained vault. Capping here would let vault throttling reduce
LP exit value even though the pool's underlying stake is unchanged. Callers
that want the immediately-withdrawable subset (JIT deployment sizing, indicative
quotes) MUST use `_effectiveBalance` instead.
The trade-off: a vault that overstates `convertToAssets` (unrealised yield not
actually withdrawable, buggy/adversarial vault) inflates `_assetBalanceV4` →
inflates `previewDeposit`/`previewWithdraw` → dilutes new depositors and may
brick withdrawals at `_ensureERC20`'s maxWithdraw cap. This is bounded by the
documented vault-trust assumption: operators must use trusted ERC-4626 vaults.


```solidity
function _assetBalanceV4(PoolId poolId, Currency currency) internal view returns (uint256 bal);
```

### _effectiveBalance

Liquidity-ready balance for a single (pool, currency) pair. Same composition as
`_assetBalanceV4`, but caps the vault contribution at this pool's PRO-RATA share
of `vault.maxWithdraw(this)` so callers requesting "what can be deployed right
now" see the truth even when the vault is paused, capped, or
utilization-constrained.
Pro-rata cap detail: `maxWithdraw(this)` is hook-wide across all pools sharing
this vault. A naive cap at the global value would let pool A see liquidity that
actually belongs to pool B (or vice versa), enabling cross-pool DoS during vault
utilization spikes. The fix scales the global cap by this pool's share of total
hook-held vault shares: `poolMax = globalMax * poolShares / totalVaultShares`.


```solidity
function _effectiveBalance(PoolId poolId, Currency currency) internal view returns (uint256 bal);
```

### _effectiveAssets

Pool-level effective (immediately-withdrawable) assets across both currencies.


```solidity
function _effectiveAssets(PoolKey calldata key) internal view returns (uint256 amount0, uint256 amount1);
```

### _effectiveAssets

Pool-level effective assets when the caller already has the PoolId cached.


```solidity
function _effectiveAssets(PoolId poolId, Currency currency0, Currency currency1)
    internal
    view
    returns (uint256 amount0, uint256 amount1);
```

### _pullAsset

Pulls underlying ERC-20 from `from` via `safeTransferFrom`, measures the actual
receipt (FoT/rebasing token defense), then routes:
- If a vault is configured for this `(pool, currency)`, deposits to the vault
(updating `_vaultShares`).
- Otherwise, credits the per-pool `_state.erc20` counter.


```solidity
function _pullAsset(VaultId vaultId, address asset, address from, uint256 want)
    internal
    override
    returns (uint256 received);
```

### _pushAsset

Ensures the per-pool `_state.erc20` holds at least `amount` -- redeems claims
and/or withdraws from the configured vault as needed -- then transfers via
`Currency.transfer` (USDT-safe).


```solidity
function _pushAsset(VaultId vaultId, address asset, address to, uint256 amount) internal override;
```

### _assetBalance

Sums the per-(pool, currency) ERC-4626 vault assets (via `convertToAssets`),
ERC-6909 claims, and tracked ERC-20.


```solidity
function _assetBalance(VaultId vaultId, address asset) internal view override returns (uint256);
```

### _depositToVault

Deposit `amount` of `currency` into the pool's configured ERC4626 vault. Caller
must have already transferred `amount` tokens to this contract. If no vault is
configured, the amount is tracked in `_state.erc20` instead. Assumes the vault
is already approved (subclasses approve at pool init via `_approveVault`).
## Vault trust model
The hook holds standing max allowance to each (pool, currency) vault. A
compromised or upgradeable vault for currency X can in principle `transferFrom`
the hook's full balance of X -- including raw ERC-20 attributed to unrelated
pools that share that currency. Operators MUST select vaults whose security
properties they understand (immutable / non-upgradeable preferred).


```solidity
function _depositToVault(PoolId poolId, Currency currency, uint256 amount) internal;
```

### _depositAllToVaults

Deposit all of the pool's tracked ERC-20 balance for both currencies into vaults.
Called in afterSwap after the JIT cycle resolves.


```solidity
function _depositAllToVaults(PoolId poolId, PoolKey calldata key) internal;
```

### _depositAllToVault

Deposit the pool's tracked ERC-20 balance of a currency into its vault. No-op
for non-vaulted pools (the balance stays in `_state.erc20`). Pre-credits
`_vaultShares` to keep view callers coherent through the deposit callback.
Relies on the init-time max approval so swap teardown does not pay an allowance
read on every vaulted currency.


```solidity
function _depositAllToVault(PoolId poolId, Currency currency) internal;
```

### _withdrawFromVault

Withdraw `amount` of `currency` from the pool's vault, crediting per-pool ERC-20.
Caps at `vault.maxWithdraw` to handle paused or utilization-constrained vaults
gracefully.


```solidity
function _withdrawFromVault(PoolId poolId, Currency currency, uint256 amount) internal;
```

### _ensureERC20

Ensure the pool's tracked ERC-20 balance is at least `amount`, then debit it.
Withdraws from the vault for any shortfall, reverts with `VaultLiquidityShortfall`
if the vault can't cover.


```solidity
function _ensureERC20(PoolId poolId, Currency currency, uint256 amount) internal;
```

### _approveVault

Set max approval for a vault using OZ `forceApprove` (zeros out first for
USDT-style tokens). Subclasses MUST call this once per (currency, vault) pair
at pool initialization, before any vault deposit can occur.


```solidity
function _approveVault(Currency currency, address vault) internal;
```

### _ensureVaultAllowance

Ensure the hook's allowance to `vault` for `currency` is at least `amount` for the
current operation. Refreshes to `type(uint256).max` only when below the required
threshold — a no-op for tokens that don't decrement allowance on transfer (the
common case), and a recovery path for USDT-style tokens whose post-init
max-allowance is gradually consumed by ordinary deposits.
Without this guard, the JIT cycle would brick on the first deposit after the
cumulative deposit volume crossed `type(uint256).max` — no real-world threshold,
but unbounded for tokens that decrement on every transfer (USDT) and bricks the
pool until owner manually calls `refreshVaultApproval`.


```solidity
function _ensureVaultAllowance(Currency currency, address vault, uint256 amount) internal;
```

### _redeemPoolClaims

Redeem this pool's ERC-6909 claims to ERC-20 via the PoolManager. Only callable
within a v4 unlock context. Increments `_state.erc20` by the redeemed amount and
returns the post-redeem balance so callers don't need a follow-up SLOAD.


```solidity
function _redeemPoolClaims(PoolId poolId, Currency currency) internal returns (uint256 erc20Bal);
```

### _recordClaims

Record newly minted ERC-6909 claims for a pool. Called after `poolManager.mint()`
in the JIT delta resolution.


```solidity
function _recordClaims(PoolId poolId, Currency currency, uint256 amount) internal;
```

### _debitPoolERC20

Debit `amount` from the pool's tracked ERC-20 balance after a PM settlement.
The actual `_settle` call is the subclass's responsibility -- this function only
updates the per-pool counter.


```solidity
function _debitPoolERC20(PoolId poolId, Currency currency, uint256 amount) internal;
```

### _poolManager

Subclasses must provide access to the v4 PoolManager. Required for claim
operations (`burn`, `take`) in `_redeemPoolClaims`.


```solidity
function _poolManager() internal view virtual returns (IPoolManager);
```

## Errors
### VaultLiquidityShortfall
The vault cannot satisfy the requested withdrawal amount (e.g., paused or capped).


```solidity
error VaultLiquidityShortfall();
```

### CrossPoolShareLeak
A vault redemption returned more shares than the pool owns. Defensive check --
should never trigger if `_vaultShares` accounting is consistent.


```solidity
error CrossPoolShareLeak();
```

### InsufficientPoolBalance
`_debitPoolERC20` was asked to pay more than the pool's tracked ERC-20 balance.


```solidity
error InsufficientPoolBalance();
```

### ZeroSharesMinted
`vault.deposit` returned zero shares for a non-zero asset deposit. Either the
vault enforces a minimum deposit threshold the pool's amount didn't meet, or the
vault is misconfigured. Reverting fail-fast prevents asset loss into a vault
that gives no claim back.


```solidity
error ZeroSharesMinted();
```

## Structs
### CurrencyState
Per-(pool, currency) packed balance state. Co-locates ERC-20 holdings and
ERC-6909 claim balance in a single 32-byte slot so the pair-aware code paths
(`_assetBalance`, `_redeemPoolClaims`) read both with one SLOAD instead of two.
`uint128` per field admits balances up to ~3.4e38, which dwarfs any plausible
per-pool token amount; deposits/credits SafeCast on write.


```solidity
struct CurrencyState {
    uint128 erc20;
    uint128 claims;
}
```

