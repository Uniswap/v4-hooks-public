# PoolVault
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0c68c6912ec9b3df692fd62740997db52f245b7d/src/alf/base/PoolVault.sol)

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
(e.g., DualPoolHook) integrate naturally.
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
## Vault Compatibility
PoolVault interacts with the configured per-currency vault solely through the
ERC-4626 interface (`deposit`, `withdraw`, `convertToAssets`, `convertToShares`,
`previewRedeem`). It deliberately does NOT read `maxWithdraw` on the hot paths
(`_effectiveBalance`, `_withdrawFromVault`, `_ensureERC20`) — curated/gated vaults
such as Morpho VaultV2 return `0` from `maxWithdraw` by construction because they
cannot honestly bound a single-block withdrawal cap across their internal
allocations. Effective-liquidity sizing instead uses `previewRedeem(shares)`,
which on every conformant vault reflects the realizable exit value per share
(net of any exit fee), and `withdraw` is called optimistically — if the vault
cannot satisfy the request from its current allocation, the revert bubbles up
through `_pushAsset` → swap callback → `beforeSwap`. Routers and aggregators
see an explicit failure and route elsewhere.
For curated/gated vaults (Morpho VaultV2 and similar), the curator gate is an
accepted trust assumption: operators MUST select vaults whose curators they
trust not to enable a denial gate against the hook. See `_depositToVault` for
the broader vault-trust model.
**Fee-on-entry / fee-on-exit vaults are NOT supported** and are rejected at
pool initialization by `_requireFeelessVault`. Two reasons compound:
1. JIT-cycle bleed. Every swap does `_ensureERC20` (vault withdraw) → swap →
`_depositAllToVaults` (vault deposit). A vault with `f_in + f_out = 20bps`
of round-trip fee bleeds 20bps of the JIT-deployed notional PER SWAP,
charged entirely to LPs. At typical hook utilization this dwarfs the LP
fee revenue.
2. LP share-math socialization. `_assetBalanceV4` reads `convertToAssets`
(gross per EIP-4626), but actual `vault.deposit`/`vault.withdraw` net out
the fee. The mismatch is socialized: a depositor underpays the entry fee
(existing LPs subsidize), and a withdrawer over-extracts the gross
valuation (remaining LPs pay the exit fee). Manifests as a
first-out-wins / last-out-loses redemption race.

See `MultiAssetVault` for the share-math + lifecycle. This contract is the V4
binding: it translates `PoolKey` / `PoolId` / `Currency` into the base's
`VaultId` / `address asset` plumbing, and adds the V4-specific helpers
(`_redeemPoolClaims`, `_recordClaims`, `_debitPoolERC20`) that the JIT lifecycle
in subclasses calls during swap callbacks.

**Note:**
security-contact: security@uniswap.org


## State Variables
### DEFAULT_DECIMALS_OFFSET
Default virtual-shares offset (also the upper clamp for the per-pool derivation).
Correct for 18-decimal pairs; matches the base `MultiAssetVault` default.


```solidity
uint8 private constant DEFAULT_DECIMALS_OFFSET = 12
```


### MIN_DECIMALS_OFFSET
Lower clamp on the per-pool offset, keeping the inflation defense at >= `1e6`
virtual shares even for low-decimal pairs.


```solidity
uint8 private constant MIN_DECIMALS_OFFSET = 6
```


### DECIMALS_OFFSET_MARGIN
Subtracted from a pair's average decimals so an 18/18 pair maps to the default 12.


```solidity
uint8 private constant DECIMALS_OFFSET_MARGIN = 6
```


### FALLBACK_DECIMALS
Assumed decimals for tokens that don't implement the optional `decimals()` metadata.


```solidity
uint8 private constant FALLBACK_DECIMALS = 18
```


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


### minDepositBlocks
Per-pool minimum deposit-lock duration, measured in `BlockNumberish`-clock blocks.

Returned by `_minDepositBlocks(VaultId)` and consumed by the base
`MultiAssetVault._withdraw` guard. `0` means no lock (same-block withdraw allowed);
`1` reproduces the legacy same-block ban; `N > 1` requires `N` blocks to elapse
between the depositor's last `_deposit` and any `_withdraw`. Set at pool
initialization and immutable thereafter.


```solidity
mapping(PoolId => uint64) public minDepositBlocks
```


### _poolDecimalsOffset
Per-pool virtual-shares offset, derived from the pair's token decimals at pool
initialization and immutable thereafter. See [_decimalsOffset](/src/alf/base/PoolVault.sol/abstract.PoolVault.md#_decimalsoffset) and
[_initDecimalsOffset](/src/alf/base/PoolVault.sol/abstract.PoolVault.md#_initdecimalsoffset) for the rationale and formula. `0` means "not initialized",
which `_decimalsOffset` maps to the base default of 12.


```solidity
mapping(PoolId => uint8) internal _poolDecimalsOffset
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


### decimalsOffset

The virtual-shares offset used by a pool's bootstrap floor and share-price
inflation defense (`100 * 10**offset` minimum bootstrap shares; `10**offset`
virtual shares in the conversion math). Derived from the pair's token decimals
at initialization. Useful for off-chain bootstrap sizing.


```solidity
function decimalsOffset(PoolId poolId) external view returns (uint8);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to read the offset for.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint8`|The pool's decimals offset (12 if the pool was never initialized).|


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
DELIBERATE VIEW-ASYMMETRY WITH `_effectiveBalance`:
- `_assetBalanceV4` uses `vault.convertToAssets(shares)` -- the gross per-share
economic value of the pool's vault stake, ignoring any vault-side exit fee
or temporary throttle.
- `_effectiveBalance` uses `vault.previewRedeem(shares)` -- the net amount the
vault would deliver right now if the hook called `withdraw`/`redeem` for
those shares (i.e., after exit fees, but still subject to single-block
liquidity races on curated/gated vaults).
Why the asymmetry: LP shares represent the pool's TRUE economic claim, including
capital that is temporarily locked behind a vault pause, a not-yet-realized exit
fee, or a curated allocation. Sizing LP share math by `previewRedeem` would let
a vault unilaterally tax LP exits (a vault that raises its exit-fee parameter
between an LP deposit and an LP withdraw would shrink LP value even though the
underlying economic stake is unchanged). The JIT cycle, by contrast, MUST size
against what `vault.withdraw` will actually return mid-swap, which is exactly
what `previewRedeem` reports.
Note that `previewRedeem` is a view at read-time; vault state could shift
between the read and the actual `vault.withdraw` call mid-swap. When that
happens, the vault reverts and the revert bubbles through `_pushAsset` →
`beforeSwap` per the documented vault-compatibility model.
The trade-off: a vault that overstates `convertToAssets` (unrealized yield not
actually withdrawable, buggy/adversarial vault) inflates `_assetBalanceV4` →
inflates `previewDeposit`/`previewWithdraw` → dilutes new depositors and may
cause `_ensureERC20` to revert mid-swap when the vault cannot satisfy the
requested withdrawal. This is bounded by the documented vault-trust assumption:
operators must use trusted ERC-4626 vaults.


```solidity
function _assetBalanceV4(PoolId poolId, Currency currency) internal view returns (uint256 bal);
```

### _effectiveBalance

Net realizable balance for a single (pool, currency) pair. Same composition as
`_assetBalanceV4`, but the vault contribution is the per-share `previewRedeem`
output -- the amount the vault would deliver if the hook redeemed exactly the
pool's share count right now. Used by callers that need "what can actually be
delivered to a swapper this block": JIT deployment sizing and indicative quotes.
Why `previewRedeem` and not `maxWithdraw`: curated/gated vaults like Morpho
VaultV2 return `0` from `maxWithdraw` by construction (they cannot honestly
bound a single-block withdrawal cap across their internal allocations), so a
`maxWithdraw`-based sizing would silently degrade every such pool to zero
deployable liquidity. `previewRedeem` is exact on VaultV2 (== `convertToAssets`)
and on fee-charging vaults correctly reports the post-fee realizable value.
Cross-pool isolation is automatic: `previewRedeem` is per-share, so pool A's
reported balance is its own share-count × per-share value, independent of
what other pools sharing the same vault hold.


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
receipt, then routes:
- If a vault is configured for this `(pool, currency)`, deposits to the vault
(updating `_vaultShares`).
- Otherwise, credits the per-pool `_state.erc20` counter.
Fee-on-transfer / rebasing tokens are UNSUPPORTED. The receipt is measured against
the hook's balance delta, and any shortfall (`received < want`, i.e. the token took
a transfer fee) reverts `TransferReceiptShortfall` — for BOTH the bootstrap and the
`addLiquidity` deposit paths, so a fee-charging token can never seed an unswappable
pool. This is a deposit-time check only: it cannot catch a token that begins
charging a fee or rebases DOWN after the deposit, so operators must still restrict
pools to non-FoT, non-rebasing tokens.


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

### _minDepositBlocks

Minimum number of `BlockNumberish`-clock blocks that must elapse between a
depositor's last `_deposit` and any subsequent `_withdraw` on the same vault.

Looks up the per-pool lock duration set at pool initialization.


```solidity
function _minDepositBlocks(VaultId vaultId) internal view override returns (uint64);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`|The vault to look up the lock for. Default impl ignores it.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint64`|blocks  Number of `BlockNumberish`-clock blocks the lock spans.|


### _decimalsOffset

Number of "virtual shares" decimal places used in the inflation defense for a
specific vault. The conversion math reads `supply + 10**_decimalsOffset(vaultId)`
so an attacker's post-bootstrap donation is diluted across the virtual position.

Returns the per-pool offset derived from the pair's token decimals at init (see
[_initDecimalsOffset](/src/alf/base/PoolVault.sol/abstract.PoolVault.md#_initdecimalsoffset)). The base default `12` is correct for 18-decimal pairs but
makes the bootstrap floor (`100 * 10**12` base units) absurdly large for low-decimal
pairs — e.g. ~100M tokens/side for a 6/6 stablecoin pair — so without this override
common stablecoin pools could not be bootstrapped at a realistic size. A pool that
was never initialized maps to `12`.


```solidity
function _decimalsOffset(VaultId vaultId) internal view override returns (uint8);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vaultId`|`VaultId`|The vault to look up the offset for. Default impl ignores it.|


### _initDecimalsOffset

Derive and cache a pool's virtual-shares offset from its currencies' `decimals()`:
`clamp((d0 + d1) / 2 - 6, 6, 12)`. This keeps the bootstrap floor (`100 * 10**offset`
base units) at a realistic per-side seed for the pair while keeping the `10**offset`
virtual-share inflation defense at least `1e6`:
- 18/18 → 12 (floor ~1e-4 token/side; unchanged from the prior hardcoded default)
- 6/6   → 6  (floor ~100 tokens/side, e.g. ~100 USDC, vs. ~100M before)
- 6/18  → 6, 8/8 → 6, etc.
The drift at the floor is ~1% regardless of offset (the floor is defined to give
~1% drift); the offset only sets the absolute minimum seed and the defense strength,
which move together. Tokens that don't implement `decimals()` fall back to 18.
Called once per pool at initialization; the result is immutable thereafter, so the
conversion math reads a stable value for the pool's lifetime.


```solidity
function _initDecimalsOffset(PoolId poolId, Currency currency0, Currency currency1) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|   The pool whose offset to derive and store.|
|`currency0`|`Currency`|The pool's first currency.|
|`currency1`|`Currency`|The pool's second currency.|


### _tokenDecimals

Read a token's `decimals()`, defaulting to `FALLBACK_DECIMALS` for tokens that do
not implement the optional metadata extension. Used only at pool initialization.


```solidity
function _tokenDecimals(Currency currency) private view returns (uint8);
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
The (pool, currency) → vault BINDING is immutable, but the standing ALLOWANCE is
not: `_revokeVaultApproval` zeroes it, and a subclass MAY expose an owner-only
emergency action that revokes the allowance, disables deposits, and pauses the
pool atomically to cap the damage window when a vault incident is detected.
Curated/gated vaults (e.g., Morpho VaultV2) add a third trust dimension on top
of share-price and allowance trust: the curator can enable a gate that denies
future deposits or withdrawals from the hook. Operators MUST trust the chosen
vault's curator not to weaponize the gate against the pool.


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
for non-vaulted pools (the balance stays in `_state.erc20`). Relies on the
init-time max approval so swap teardown does not pay an allowance read on every
vaulted currency.
Unlike `_depositToVault` (LP deposit path, surfaces vault rejection directly to
the caller), this function wraps `vault.deposit` in `try/catch`. The caller here
is the JIT cycle's afterSwap settlement -- the swap itself has already executed
and a deposit-side revert would gratuitously brick swaps for an operator-vault
misconfiguration (e.g., `maxDeposit` cap reached, curated allocator rejection,
paused vault). On failure the `try` block's state changes atomically revert, so
`s.erc20` and `_vaultShares` are untouched; we just emit `VaultDepositSkipped`
and continue. LPs forgo vault yield on the un-deposited amount until the next
cycle retries, but trading remains live.


```solidity
function _depositAllToVault(PoolId poolId, Currency currency) internal;
```

### _withdrawFromVault

Withdraw `amount` of `currency` from the pool's vault, crediting per-pool ERC-20.
Calls `vault.withdraw` optimistically -- if the vault cannot satisfy the request
(paused, utilization-constrained, curated-allocation shortfall), the vault's own
revert bubbles up through `_pushAsset` → swap callback → `beforeSwap`. The
`CrossPoolShareLeak` defensive check stays to catch a vault that consumes more
shares than the pool owns.


```solidity
function _withdrawFromVault(PoolId poolId, Currency currency, uint256 amount) internal;
```

### _drainVaultBestEffort

Best-effort full withdrawal of the pool's vault position for `currency` back into
the per-pool raw ERC-20 ledger. Redeems exactly the pool's own `_vaultShares` (never
a sibling pool's), so cross-pool isolation is preserved.
Wrapped in try/catch by design: this is the rescue leg of an emergency response
against a suspect-but-still-cooperative vault. A bricked / paused vault that reverts
on `redeem` MUST NOT block the surrounding revocation + pause, so on failure this is
a no-op (assets stay in the vault, `_vaultShares` untouched) and emits
[VaultDrainSkipped](/src/alf/base/PoolVault.sol/abstract.PoolVault.md#vaultdrainskipped). On success the position moves to `s.erc20`: vault assets become
raw ERC-20, outside the suspect vault's reach.


```solidity
function _drainVaultBestEffort(PoolId poolId, Currency currency) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|  The pool whose vault position to drain.|
|`currency`|`Currency`|The currency to withdraw from the vault.|


### _ensureERC20

Ensure the pool's tracked ERC-20 balance is at least `amount`, then debit it.
Withdraws any shortfall from the configured vault by calling `vault.withdraw`
directly; on vault failure (paused, curated shortfall, etc.) the revert bubbles
up through `_pushAsset` → swap callback → `beforeSwap`. Routers / aggregators
see the vault-side error (e.g., Morpho's `NotEnoughLiquidity`) rather than a
uniform PoolVault sentinel.
For non-vaulted pools the `bal - amount` subtraction below panics on underflow
when the pool has no configured vault and insufficient ERC-20 -- there is no
separate sentinel revert.


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

### _revokeVaultApproval

Zero the hook's standing approval to a vault -- the emergency counterpart to
`_approveVault`. Uses `forceApprove(0)` (a non-zero→zero transition, safe for
USDT-style tokens) so a vault suspected compromised can no longer `transferFrom`
the hook's balance of `currency`. No-op for `address(0)` (non-vaulted currency).
NOTE: the LP deposit path re-arms the allowance via `_ensureVaultAllowance` on the
next `vault.deposit`. Callers MUST stop deposits (pause the pool AND disable
external deposits) in the same transaction, or the revocation will not hold.


```solidity
function _revokeVaultApproval(Currency currency, address vault) internal;
```

### _requireFeelessVault

Reject ERC-4626 vaults that apply entry or exit fees. Called once per vault at
pool initialization; no-ops for `address(0)` (non-vaulted currency).
Detection leverages the EIP-4626 contract that `convertToShares`/`convertToAssets`
MUST NOT factor in fees, while `previewDeposit`/`previewRedeem` MUST. For a feeless
vault:
- `previewDeposit(probe) == convertToShares(probe)` (both round DOWN)
- `previewRedeem(probe)  == convertToAssets(probe)` (both round DOWN)
Any divergence is an honest report of a fee. The probe is `10**vault.decimals()`
so any per-mille-or-larger fee shows up well above rounding noise.
Note that this guard only catches honest fee disclosures. An adversarial vault
could lie at the preview level and charge fees only on actual deposit/withdraw;
the LP-side socialization documented in the contract-level `Vault Compatibility`
NatSpec would still apply in that case. Operators are trusted to pick curated
vaults whose preview functions reflect ground truth.


```solidity
function _requireFeelessVault(IERC4626 vault) internal view;
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
A claim is an accounting credit, backed by real tokens in the PoolManager only once
the corresponding swapper has settled. Claims minted by an EARLIER swap on this pool
within the SAME, still-unsettled transaction (multiple swaps on one pool inside a
single `unlock`) are therefore not yet physically backed: the swapper's input lands
at end-of-unlock, not now. Taking the full claim balance would attempt to transfer
tokens the PoolManager does not yet hold and revert the later swap.
Cap the physical `take` at the PoolManager's current balance of `currency` and burn
only that much; leave any remainder as recorded claims. The deployment shortfall is
sourced from the vault by the caller (`_deployJIT` withdraws `totalNeed - onHand`),
and the residual claims redeem on a later cycle once their backing has settled. The
common path (claims fully backed) is unchanged: `available >= claimBal`, so the full
balance is redeemed exactly as before.


```solidity
function _redeemPoolClaims(PoolId poolId, Currency currency) internal returns (uint256 erc20Bal);
```

### _unbackedClaims

The portion of a pool's recorded claims that the PoolManager cannot physically
honor right now: claims whose backing settle is still pending in this transaction
(e.g. minted by an earlier same-pool swap inside one unlock). `_deployJIT` excludes
this from the deployable balance so it never sizes liquidity against funds it cannot
source this cycle — `_redeemPoolClaims` can only redeem the backed portion, and the
vault does not hold the claim portion, so counting it would over-draw the vault.
Returns 0 in the common case (claims fully backed), so steady-state sizing is
unaffected.


```solidity
function _unbackedClaims(PoolId poolId, Currency currency) internal view returns (uint256);
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

## Events
### VaultDepositSkipped
The JIT cycle's post-swap `vault.deposit` reverted (typically because the
vault's `maxDeposit` cap is reached, or a curated allocator declined). The
underlying ERC-20 stays in `_state.erc20` and is retried on the next swap.
LP share math remains correct because `_assetBalanceV4` reads
`s.erc20 + s.claims + vault` -- LPs simply forgo vault yield on the
non-deposited portion until the cap loosens or operator intervention.


```solidity
event VaultDepositSkipped(PoolId indexed poolId, Currency indexed currency, uint256 amount, bytes reason);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|  The pool whose afterSwap re-deposit was skipped.|
|`currency`|`Currency`|The currency whose vault rejected the deposit.|
|`amount`|`uint256`|  The asset amount that could not be deposited (kept in `s.erc20`).|
|`reason`|`bytes`|  The raw revert data from `vault.deposit` (for operator diagnostics).|

### VaultDrained
Emitted when `_drainVaultBestEffort` successfully pulls the pool's full vault
position back into the raw ERC-20 ledger (e.g. during an emergency revocation).


```solidity
event VaultDrained(PoolId indexed poolId, Currency indexed currency, uint256 shares, uint256 assets);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|  The pool whose vault position was drained.|
|`currency`|`Currency`|The currency that was withdrawn from the vault.|
|`shares`|`uint256`|  The vault shares redeemed (the pool's full holding).|
|`assets`|`uint256`|  The asset amount received and credited to `s.erc20`.|

### VaultDrainSkipped
Emitted when a best-effort vault drain could not complete (vault paused, bricked,
or otherwise reverting on redeem). The assets remain in the vault; the caller
continues so the surrounding action (e.g. allowance revocation + pause) still lands.


```solidity
event VaultDrainSkipped(PoolId indexed poolId, Currency indexed currency, uint256 shares, bytes reason);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|  The pool whose vault drain was skipped.|
|`currency`|`Currency`|The currency whose vault rejected the redeem.|
|`shares`|`uint256`|  The vault shares that could not be redeemed.|
|`reason`|`bytes`|  The raw revert data from `vault.redeem` (for operator diagnostics).|

## Errors
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

### VaultChargesEntryFee
The configured ERC-4626 vault applies an entry fee (`previewDeposit < convertToShares`).
PoolVault deliberately does not support fee-on-entry vaults: see the contract-level
`Vault Compatibility` NatSpec for the structural reasons (JIT-cycle bleed + share-math
socialization). Detected at pool init via the probe in `_requireFeelessVault`.


```solidity
error VaultChargesEntryFee();
```

### VaultChargesExitFee
The configured ERC-4626 vault applies an exit fee (`previewRedeem < convertToAssets`).
Same rationale as `VaultChargesEntryFee`; see contract-level `Vault Compatibility`.


```solidity
error VaultChargesExitFee();
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

