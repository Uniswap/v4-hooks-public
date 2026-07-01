# DualPoolHook
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/DualPoolHook.sol)

**Inherits:**
[OwnedALFHook](/src/alf/base/OwnedALFHook.sol/abstract.OwnedALFHook.md), [PoolVault](/src/alf/base/PoolVault.sol/abstract.PoolVault.md), ReentrancyGuardTransient, IUnlockCallback

**Title:**
DualPoolHook

**Author:**
Uniswap Labs

JIT quoter with ERC4626 vault rehypothecation and multi-range liquidity
distribution. Pricing is fully static: pool fees are set at deploy time via
`PoolKey.fee` and never change.
Assets are deployed across multiple tick ranges ("buckets") during each JIT cycle,
with owner-configured weights that control capital concentration. Token allocation
across buckets uses `getLiquidityForAmounts` at the current price so that no capital
sits idle, even when the price has drifted and ranges are asymmetric.
Example: 75% at [-10,10], 15% at [-30,30], 10% at [-60,60] concentrates most
liquidity around the peg while maintaining depth for larger price moves.
## JIT Lifecycle
beforeSwap:
1. Set the JIT lock (blocks reentrant addLiquidity/removeLiquidity/setDistribution)
2. Compute per-bucket liquidity from current assets and weights
3. Compute exact token amounts needed via SqrtPriceMath
4. Redeem claims, withdraw only the shortfall from vaults
5. Deploy each bucket as a concentrated LP position
[pool executes swap against the deployed LP with fee override]
afterSwap:
1. Remove all bucket positions
2. Settle net deltas (negative → ERC-20 to PM, positive → mint claims),
debiting per-pool ERC-20 tracking on settle
3. Re-deposit remaining per-pool ERC-20 to vaults
4. Clear the JIT lock
## Pricing
The pool's LP fee is read from `PoolKey.fee` and charged natively by v4 on every
swap. The fee is fixed at pool-creation time and cannot be changed afterwards. The
owner has only a per-pool liveness flag (`setPoolLive`) for emergency pause; the
hook intentionally ignores hookData on swaps.
## Share Accounting
Inherited from PoolVault. Pools are seeded by the owner via `bootstrap`, which mints
`sqrt(amount0 * amount1)` shares (Uniswap V2 style). Inflation defense uses
EIP-4626 virtual-shares offsets in the conversion math (see PoolVault). After
bootstrap, anyone with deposit auth may call `addLiquidity` for proportional
shares. LPs hold proportional shares of the pool's total assets (vault shares +
claims + per-pool ERC-20).
## Reentrancy
User-facing entry points (`bootstrap`, `addLiquidity`, `removeLiquidity`) carry the
OZ `nonReentrant` transient guard. PM-driven callbacks (`_beforeSwap`, `_afterSwap`)
are not eligible for that guard (no fresh entry point), so they manage the `JITLock`
transient slots and the LP entries reject calls (via `whenJITNotInProgress`) while a
cycle is in flight. This blocks an owner-configured ERC4626 vault from re-entering LP
entry points mid-JIT.

**Note:**
security-contact: security@uniswap.org


## Constants
### LP_SALT
Salt for the hook's LP positions in the PoolManager, distinguishing them
from positions created by other hooks or LPs on the same pool.


```solidity
bytes32 private constant LP_SALT = bytes32(uint256(0x4455414C))
```


### maxMinDepositBlocks
Per-deployment upper bound on `PoolConfig.minDepositBlocks`, in
`BlockNumberish`-clock blocks. Set at construction so each chain deployment
can pick a chain-appropriate ceiling at deployment, immutable thereafter.


```solidity
uint64 public immutable maxMinDepositBlocks
```


## State Variables
### _depositGate
Per-pool gate for non-owner deposits, as a type-driven `DepositGate`. Set at
initialization via `initializePool`, toggled via `setExternalDeposits` /
`emergencyRevokeVault`, and read by `_requireDepositAuth`. Re-exposed through the
`externalDepositsEnabled` getter.


```solidity
DepositGate internal _depositGate
```


### _distribution
Per-pool liquidity distribution (tick ranges and weights), as a type-driven
`Distribution`. Set at initialization via `initializePool`, updatable via
`setDistribution`, and read by the JIT cycle through `_distribution.get(poolId)`.


```solidity
Distribution internal _distribution
```


## Functions
### constructor


```solidity
constructor(IPoolManager _pm, uint32 maxGas_, address owner_, uint64 _maxMinDepositBlocks)
    OwnedALFHook(_pm, maxGas_, owner_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pm`|`IPoolManager`|                The Uniswap v4 PoolManager.|
|`maxGas_`|`uint32`|            Gas budget declared for `getIndicativeQuote` staticcalls.|
|`owner_`|`address`|             Initial contract owner. Transferable post-deployment via OZ `Ownable2Step` (`transferOwnership` + `acceptOwnership`); `renounceOwnership` is disabled (see {OwnedALFHook}). Key loss without a pending transfer is unrecoverable.|
|`_maxMinDepositBlocks`|`uint64`|Per-deployment upper bound on `PoolConfig.minDepositBlocks`.|


### whenJITNotInProgress

Reverts {JITInProgress} if any pool served by this hook has a JIT cycle in flight.
Thin delegate over {requireJITNotInProgress}: the lock state and logic live in the
`JITLock` type, while the modifier keeps the guard visible in each entry point's
signature and hard to omit. Inherited by {DualPoolIncentivizedHook}.


```solidity
modifier whenJITNotInProgress() ;
```

### checkDeadline

Reverts [DeadlineExpired](/src/alf/DualPoolHook.sol/contract.DualPoolHook.md#deadlineexpired) if the caller-supplied `deadline` has passed. Hoisted out of
the LP entry points so the precondition stays visible in each signature.

Mixed-clock by design: deadlines compare against `block.timestamp` because they are
wall-clock UX bounds, whereas the deposit lock (`minDepositBlocks`) and rewards accrual
run on the block-based `BlockNumberish` clock as anti-MEV timing.


```solidity
modifier checkDeadline(uint256 deadline) ;
```

### initializePool

Initialize a new pool with vaults and liquidity distribution.

Calls `poolManager.initialize` internally. The pool's LP fee is taken from
`key.fee` and is static: it cannot be changed post-deployment. The vault
binding is permanent (set at creation and cannot be changed), but the standing
token allowance granted to each vault is revocable in an emergency via
`emergencyRevokeVault`. The distribution can be updated later via
`setDistribution`.
Native ETH (currency `address(0)`) is rejected; wrap as WETH instead.
The pool is created not live: swaps revert with `PoolNotLive` until the
owner calls `bootstrap`, which mints the first shares and flips liveness on.
This closes the post-init, pre-bootstrap window in which a swapper could
shift `slot0.sqrtPriceX96` against a zero-liquidity pool. After bootstrap,
the owner can pause/unpause via `setPoolLive`.
`config.minDepositBlocks` is recorded once and immutable thereafter. Its unit
is defined as blocks; this works consistently across chains by way of the
`BlockNumberish` library which returns the L2 sequencer's local block number
on Arbitrum and `block.number` elsewhere. A value of `0` means no lock applies
and same-block deposit-then-withdraw is allowed; for a same-block ban set `1`.
Values above `maxMinDepositBlocks` are disallowed.


```solidity
function initializePool(PoolKey calldata key, PoolConfig calldata config) external onlyOwner returns (int24 tick);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|   The PoolKey (must reference this hook). `key.fee` is the static LP fee; pools with the `LPFeeLibrary.DYNAMIC_FEE_FLAG` set are rejected.|
|`config`|`PoolConfig`|Pool configuration including distribution, vaults, permissions, and the deposit-lock duration.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tick`|`int24`| The initial tick assigned by the PoolManager.|


### bootstrap

Seed a pool with the first deposit. Mints `sqrt(amount0 * amount1)` shares
to the owner and flips the pool to live, enabling swaps for the first time.

Only the owner may bootstrap. The owner-supplied amounts set the initial
share/asset ratio, which is critical for asymmetric-decimal pairs (e.g.,
USDC/WETH) where a naïve 1-wei-of-each bootstrap would either be unaffordable
or set a meaningless price. Inflation defense is provided by virtual-shares
offsets in the conversion math (see {PoolVault._convertToAmounts}). Reverts
if the pool is already bootstrapped or if `sqrt(amount0 * amount1) == 0`.
Bootstrap is the sole trigger that flips a newly-initialized pool to live:
this closes the init→bootstrap window in which a swap could move slot0's
`sqrtPriceX96` against a zero-liquidity pool.


```solidity
function bootstrap(PoolKey calldata key, uint256 amount0, uint256 amount1)
    external
    onlyOwner
    nonReentrant
    whenJITNotInProgress
    returns (uint256 shares);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|    The pool to bootstrap.|
|`amount0`|`uint256`|Currency0 to deposit.|
|`amount1`|`uint256`|Currency1 to deposit.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`shares`|`uint256`|Total shares minted, all credited to the owner.|


### addLiquidity

Deposit token0 and token1 proportional to the pool's current asset ratio.

Requires owner or external deposits enabled. Pool must be bootstrapped first.
Records the depositor's deposit block; `removeLiquidity` reverts in the same
block to defend against atomic deposit-swap-withdraw fee/yield sniping.
Slippage bounds are enforced after the actual transfers so callers cap exposure
to swaps, vault share-price moves, or MEV between off-chain `previewDeposit` and
on-chain inclusion. `deadline` MUST be `>= block.timestamp` or the call reverts.
Use `type(uint256).max` for unbounded values, but production callers SHOULD set
tight bounds.


```solidity
function addLiquidity(
    PoolKey calldata key,
    uint256 sharesToMint,
    uint256 maxAmount0,
    uint256 maxAmount1,
    uint256 deadline
) external nonReentrant whenJITNotInProgress checkDeadline(deadline) returns (uint256 amount0, uint256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|         The pool to deposit into.|
|`sharesToMint`|`uint256`|Number of shares to mint. Use `previewDeposit` to see required amounts.|
|`maxAmount0`|`uint256`|  Maximum currency0 the caller is willing to spend. Reverts if exceeded.|
|`maxAmount1`|`uint256`|  Maximum currency1 the caller is willing to spend. Reverts if exceeded.|
|`deadline`|`uint256`|    Unix timestamp after which the call reverts.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|    Actual currency0 transferred from the caller.|
|`amount1`|`uint256`|    Actual currency1 transferred from the caller.|


### removeLiquidity

Burn shares and receive proportional token0 + token1.

Amounts are rounded down to prevent over-withdrawal. Tokens are withdrawn
from vaults via `vault.withdraw` (exact assets) if the pool's tracked ERC-20
is insufficient. Reverts in the same block as the depositor's last deposit
(anti-fee-sniping).
Slippage bounds are enforced after the actual transfers so callers floor
received amounts against pool ratio moves between preview and inclusion.
`deadline` MUST be `>= block.timestamp` or the call reverts.


```solidity
function removeLiquidity(
    PoolKey calldata key,
    uint256 sharesToBurn,
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 deadline
) external nonReentrant whenJITNotInProgress checkDeadline(deadline) returns (uint256 amount0, uint256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|         The pool to withdraw from.|
|`sharesToBurn`|`uint256`|Number of shares to burn. Use `previewWithdraw` to see return amounts.|
|`minAmount0`|`uint256`|  Minimum currency0 the caller will accept. Reverts if not met.|
|`minAmount1`|`uint256`|  Minimum currency1 the caller will accept. Reverts if not met.|
|`deadline`|`uint256`|    Unix timestamp after which the call reverts.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|    Actual currency0 transferred to the caller.|
|`amount1`|`uint256`|    Actual currency1 transferred to the caller.|


### unlockCallback

Called by the pool manager on `msg.sender` when the manager is unlocked

Only callable by the PoolManager as a re-entrant continuation of our own
`poolManager.unlock` call inside `removeLiquidity`. Anyone calling this directly
with crafted data could trigger an arbitrary LP withdraw, so the `msg.sender`
check is critical.
The encoded payload is `(PoolKey key, address owner, uint256 sharesToBurn)`. The
callback redeems both currencies' ERC-6909 claims first (cheap inside an unlock
context, satisfies the `s.erc20`-only inspection in `_ensureERC20`), then runs
`_withdraw` to mint payouts to `owner`.


```solidity
function unlockCallback(bytes calldata data) external returns (bytes memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`data`|`bytes`|The data that was passed to the call to unlock|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes`|Any data that you want to be returned from the unlock call|


### setDistribution

Replace the liquidity distribution for a pool.

Weights must sum to 10_000. Ticks must be aligned to tickSpacing.
Buckets can be asymmetric, overlapping, or non-contiguous.
Reverts during an active JIT cycle to prevent orphaning live LP positions.


```solidity
function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets)
    external
    onlyOwner
    whenJITNotInProgress;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|    The pool to update.|
|`buckets`|`LiquidityBucket[]`|The new distribution (1 to MAX_BUCKETS entries).|


### refreshVaultApproval

Refresh the max-approval the hook grants to a pool's ERC-4626 vault.

Recovery path for vaults whose allowance is unexpectedly consumed or reset.
`forceApprove` internally zeroes-then-sets for USDT-style tokens whose
`approve` reverts on a non-zero existing allowance, so a single call covers
both the well-behaved and the zero-out-first cases. No-op if the pool has no
vault configured for `currency`.


```solidity
function refreshVaultApproval(PoolKey calldata key, Currency currency) external onlyOwner whenJITNotInProgress;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|     The pool whose vault allowance should be refreshed.|
|`currency`|`Currency`|Which side (currency0 or currency1) to refresh.|


### emergencyRevokeVault

Emergency incident-response lever for a suspect vault: in one atomic action,
pause the pool, disable external deposits, zero both currencies' vault allowances,
and best-effort withdraw the pool's vault-held assets back into the hook. Use when
a configured vault is suspected compromised, paused, or pending a risky upgrade.

The pool's vault binding is immutable, so this does not remove the vault. Four
actions run in order; the first three always succeed, the fourth is best-effort:
1. Pause (`livePools = false`): blocks swaps so the JIT cycle stops touching
the vault.
2. Disable external deposits: load-bearing, because `addLiquidity` is not gated
on liveness, so an external depositor could otherwise re-arm the allowance
via `_ensureVaultAllowance` on the deposit path even while the pool is paused.
3. Zero both vault allowances: removes the standing `type(uint256).max` grant
that lets a vault `transferFrom` the hook's raw balance of that currency
(including ERC-20 attributed to other pools sharing it; see {PoolVault}
`Vault trust model`).
4. Best-effort drain (`_drainVaultBestEffort`): redeems the pool's vault shares
back to raw ERC-20, rescuing assets already inside the vault, which step 3
alone does not protect. Wrapped in try/catch: if the vault is bricked/paused
and reverts on redeem, the rescue is skipped (emits [PoolVault-VaultDrainSkipped](/src/alf/base/PoolVault.sol/abstract.PoolVault.md#vaultdrainskipped))
but the revocation + pause above still hold. `nonReentrant` because this is
the only owner path that makes an external call to the (untrusted) vault.
`removeLiquidity` is intentionally left open so LPs can still exit; it needs no
hook to vault allowance, so exits neither re-arm the exposure nor get trapped. To
resume normal operation the owner re-approves via [refreshVaultApproval](/src/alf/DualPoolHook.sol/contract.DualPoolHook.md#refreshvaultapproval) and
re-enables liveness / external deposits, which re-arms the exposure, so the
underlying vault incident must be resolved first.


```solidity
function emergencyRevokeVault(PoolKey calldata key) external onlyOwner nonReentrant whenJITNotInProgress;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool whose vault exposure to revoke.|


### setExternalDeposits

Enable or disable external (non-owner) deposits for a pool.


```solidity
function setExternalDeposits(PoolKey calldata key, bool enabled) external onlyOwner whenJITNotInProgress;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|    The pool to configure.|
|`enabled`|`bool`|True to permit non-owner `addLiquidity`, false for owner-only.|


### externalDepositsEnabled

Whether non-owner addresses may currently deposit into a pool.


```solidity
function externalDepositsEnabled(PoolId poolId) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|Whether non-owner deposits are permitted.|


### setPoolLive

Enable or disable pool liveness for emergency pause/resume.

When toggled to false, `_beforeSwap` reverts with {PoolNotLive}, pausing the
pool for swaps. The static fee (`key.fee`) is unaffected; re-enabling
immediately restores trading at the original rate.


```solidity
function setPoolLive(PoolKey calldata key, bool live) external onlyOwner whenJITNotInProgress;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`| The pool to toggle.|
|`live`|`bool`|True to make swaps execute against JIT liquidity, false to pause the pool.|


### getReserves

Total reserves managed by this hook for the given pool.

Includes ERC-20, ERC-6909 claims, and ERC4626 vault balances.


```solidity
function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1);
```

### getEffectiveLiquidity

Assets available for immediate swapping.

Sizes vault-side balance via `vault.previewRedeem(shares)` so the reported
number reflects the net realizable exit value (accounting for any vault-side
exit fee) rather than the gross `convertToAssets` figure. Curated/gated
vaults that return `0` from `maxWithdraw` (Morpho VaultV2 and similar) are
correctly sized via `previewRedeem` instead.


```solidity
function getEffectiveLiquidity(PoolKey calldata key)
    external
    view
    override
    returns (uint256 token0, uint256 token1);
```

### getIndicativeQuote

Indicative quote against hypothetical DualPool JIT liquidity.

Uses current active distribution-bucket liquidity for a compact view quote.
Ignores hookData; pricing is the static `key.fee`.
The estimate is a single constant-liquidity `computeSwapStep` (see
`_simulateIndicative`): it extrapolates the in-range bucket depth toward the
price limit, so for a swap large enough to exhaust the deployed buckets in a real
JIT cycle the raw step would report far more output than the pool holds (it can
exceed reserves several times over). `_simulateIndicative` therefore caps the
output leg at the effective output reserve. For exact output this returns 0 when
the requested output exceeds what the pool can deliver, since there is no honest
fill to price. The result stays an upper bound fit for ranking, not a precise
execution prediction; binding slippage protection belongs in the caller/router.


```solidity
function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
    external
    view
    override
    returns (uint256 outputAmount);
```

### swapToPrice

Simulate a price-bounded swap against hypothetical JIT liquidity.

Returns both legs of the fill. When the swap would exhaust the deployable output
reserve, both legs are recomputed as the exact-output cost of draining that reserve, so
the returned (amountIn, amountOut) pair is always internally consistent: amountIn prices
exactly amountOut. The result is non-binding; binding slippage protection belongs in the
caller. See `_simulateIndicative`.


```solidity
function swapToPrice(
    PoolKey calldata key,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata
) external view override returns (uint256 amountIn, uint256 amountOut);
```

### sharesOf

Returns the share balance of `user` for the given pool.


```solidity
function sharesOf(PoolKey calldata key, address user) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`| The pool whose share balance to read.|
|`user`|`address`|The address whose shares to look up.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The number of pool shares held by `user`.|


### getDistribution

Returns the current liquidity distribution for a pool.


```solidity
function getDistribution(PoolId poolId) external view returns (LiquidityBucket[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to query.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`LiquidityBucket[]`|The active list of liquidity buckets (tick ranges + weights).|


### getHookPermissions

Required v4 hook flags:
- beforeInitialize: block direct init (force initializePool)
- beforeAddLiquidity / beforeRemoveLiquidity: restrict to hook-only LP
- beforeSwap: JIT deployment + fee override
- afterSwap: JIT teardown + delta resolution


```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory);
```

### _beforeAddLiquidity

External LP additions are blocked. v4-core's `Hooks.noSelfCall` skips the hook
callback entirely when the hook itself is the caller, so the only path that
reaches this body is an external `modifyLiquidity` call, which is always rejected.


```solidity
function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
    internal
    pure
    override
    returns (bytes4);
```

### _beforeRemoveLiquidity

External LP removals are blocked. Same `noSelfCall` reasoning as `_beforeAddLiquidity`.


```solidity
function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
    internal
    pure
    override
    returns (bytes4);
```

### _beforeSwap

JIT entry point. Deploys multi-range JIT liquidity under the JIT lock. v4 charges
the static `key.fee` on the in-flight swap natively; no override is returned.
Reverts when the pool is paused (`!live`). Routers and aggregators see an explicit
failure instead of the swap running against zero deployed liquidity; the
multiplexer's per-target try/catch already handles the revert. hookData is
ignored entirely (see contract-level NatSpec).
A reentrant `_beforeSwap` on the same pool (e.g., from a malicious vault calling
`poolManager.swap(samePool)` during `_withdrawFromVault`) would corrupt the JIT
lifecycle: the inner cycle's `clear` would zero the per-pool slot while the outer
cycle is still in flight, so the outer `_afterSwap` would short-circuit and leave
the outer's deployed positions orphaned. {JITLock.enter} rejects it up-front.


```solidity
function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

### _afterSwap

JIT teardown. Removes all bucket positions, resolves the hook's net delta for both
currencies (debiting per-pool ERC-20 on settle), re-deposits remaining ERC-20 to
vaults, and clears the JIT lock. `_beforeSwap` always sets the lock when the pool
is live and reverts when it isn't, so reaching `_afterSwap` implies the lock is
set; a defensive lock read is unnecessary.


```solidity
function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
    internal
    override
    returns (bytes4, int128);
```

### _deployJIT

Deploy JIT liquidity across all distribution buckets.
Three-phase strategy:
1. **Compute allocations**: for each bucket, compute its weighted liquidity
from the full balance via `getLiquidityForAmounts`, then use `SqrtPriceMath`
to determine the exact token0 and token1 needed for deployment.
2. **Targeted withdrawal**: redeem per-pool ERC-6909 claims first (cheaper
than vault interaction), then withdraw only the shortfall from vaults.
Unneeded capital stays in the vault earning yield during the swap window.
Phase 2 reads the pool's `_erc20[poolId][currency]` tracker rather than the
hook's global `IERC20.balanceOf`, preserving cross-pool isolation when the
hook serves multiple pools sharing a currency.
3. **Deploy**: add each bucket as a concentrated LP position.


```solidity
function _deployJIT(PoolId poolId, PoolKey calldata key) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to deploy for.|
|`key`|`PoolKey`|   The pool key (for currency references and modifyLiquidity calls).|


### _deployBuckets

Deploy each bucket's LP position. Separated from _deployJIT for stack depth.
Records each deployed liquidity value in the pool's `ActiveLiquidity` transient slots
so `_removeJIT` can size its inverse `modifyLiquidity` call without a storage SLOAD.


```solidity
function _deployBuckets(
    PoolId poolId,
    PoolKey calldata key,
    LiquidityBucket[] memory buckets,
    uint128[MAX_BUCKETS] memory liqs
) private;
```

### _removeJIT

Remove all active JIT positions deployed in `_deployJIT`. Iterates the distribution
and removes each bucket that has non-zero active liquidity, reading it via
`ActiveLiquidity.takeAndClear` (which zeroes the slot on read so a later same-tx swap
on this pool does not see a stale value; see {ActiveLiquidity}). After removal, the
hook's cumulative delta reflects the net position from the deploy-swap-remove cycle.


```solidity
function _removeJIT(PoolId poolId, PoolKey calldata key) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to remove JIT positions from.|
|`key`|`PoolKey`|   The pool key (for modifyLiquidity calls).|


### _resolveNetDelta

Resolve the hook's net delta for both currencies after the JIT cycle via the single
`SettlementLib` authority. Negative delta (hook owes PM): settle from the pool's raw
ERC-20 and debit its inventory bucket. Positive delta (PM owes hook): mint ERC-6909
claims (cannot `take` because the swapper hasn't settled yet), recorded on the
bucket and redeemed in the next `_deployJIT`.


```solidity
function _resolveNetDelta(PoolId poolId, PoolKey calldata key) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to resolve deltas for (used for inventory-bucket derivation).|
|`key`|`PoolKey`|   The pool key (for currency references).|


### _simulateIndicative


```solidity
function _simulateIndicative(
    PoolKey calldata key,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96
) internal view returns (uint256 amountIn, uint256 amountOut);
```

### _requireDepositAuth

Revert unless the caller is the owner or external deposits are enabled for the pool.


```solidity
function _requireDepositAuth(PoolId poolId) internal view;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to check authorization for.|


### _requireVaultMatchesCurrency

Verify that the ERC-4626 vault's `asset()` matches the pool's currency. Skipped
for `address(0)` (no vault; currency held as raw ERC-20). Called only at
`initializePool` since the vault address is immutable thereafter.


```solidity
function _requireVaultMatchesCurrency(IERC4626 vault, Currency currency) internal view;
```

### _poolManager

Provides PoolVault access to the PoolManager for claim operations (burn/take).


```solidity
function _poolManager() internal view override returns (IPoolManager);
```

## Events
### PoolCreated
Emitted when a new pool is initialized via `initializePool`.


```solidity
event PoolCreated(PoolId indexed poolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool that was created.|

### DistributionUpdated
Emitted when the liquidity distribution is replaced via `setDistribution`.


```solidity
event DistributionUpdated(PoolId indexed poolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose distribution was updated.|

### EmergencyVaultRevoked
Emitted when the owner triggers `emergencyRevokeVault`: the pool is paused,
external deposits are disabled, and both vault token allowances are zeroed in a
single action. A monitoring signal that a vault incident response is in progress.


```solidity
event EmergencyVaultRevoked(PoolId indexed poolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose vault exposure was revoked.|

## Errors
### LiquidityNotAllowed
External address attempted to add or remove v4 pool liquidity directly.
Only the hook itself may modify LP positions (during JIT cycles).


```solidity
error LiquidityNotAllowed();
```

### InvalidHookAddress
The PoolKey's hooks address does not match this contract.


```solidity
error InvalidHookAddress();
```

### NativeNotSupported
Pool initialization rejected because one of the currencies is native ETH
(`address(0)`). PoolVault uses `IERC20.safeTransferFrom` which cannot operate on
`address(0)`, and the hook lacks a `receive() payable` function. Operators must
use a wrapped-ETH variant (e.g., WETH9) instead.


```solidity
error NativeNotSupported();
```

### VaultAssetMismatch
Configured ERC-4626 vault's `asset()` does not match the pool's currency. Vault
addresses are immutable post-init, so this fails fast instead of producing a
pool that silently mis-accounts.


```solidity
error VaultAssetMismatch();
```

### DeadlineExpired
`block.timestamp` exceeded the caller-supplied `deadline` for an LP operation.


```solidity
error DeadlineExpired();
```

### SlippageExceeded
`addLiquidity` would have transferred more than `maxAmount0`/`maxAmount1` from the
caller, or `removeLiquidity` would have transferred less than
`minAmount0`/`minAmount1` to the caller. Caller's slippage bounds were violated.


```solidity
error SlippageExceeded();
```

### Unauthorized
Caller is not authorized for this entry point. Used by `_requireDepositAuth`
and `_beforeInitialize`. Owner gating is handled by OZ Ownable's
`OwnableUnauthorizedAccount`.


```solidity
error Unauthorized();
```

### MinDepositBlocksTooLarge
Operator-supplied `PoolConfig.minDepositBlocks` exceeds the per-deployment upper
bound (`maxMinDepositBlocks`).


```solidity
error MinDepositBlocksTooLarge(uint64 supplied, uint64 max);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`supplied`|`uint64`|The value the operator provided in `PoolConfig`.|
|`max`|`uint64`|     The deployment-wide ceiling set at construction.|

### UnauthorizedCallback
`unlockCallback` was invoked by an address other than the PoolManager. The callback
reads encoded arguments and triggers an LP withdraw; only the PoolManager (acting on
behalf of our own `poolManager.unlock` call) may invoke it.


```solidity
error UnauthorizedCallback();
```

### DynamicFeeNotSupported
`key.fee` carries the `LPFeeLibrary.DYNAMIC_FEE_FLAG` (0x800000). DualPool is
designed around a static fee fixed at pool creation; dynamic-fee pools would
require the hook to maintain its own fee state and route every swap through a
fee-update callback, which the contract is explicitly not built for. Use a
concrete `uint24` fee value below `MAX_LP_FEE` instead.


```solidity
error DynamicFeeNotSupported();
```

## Structs
### PoolConfig
Configuration for initializing a new pool. Passed to `initializePool`.


```solidity
struct PoolConfig {
    uint160 sqrtPriceX96;
    LiquidityBucket[] distribution;
    bool allowExternalDeposits;
    IERC4626 vault0;
    IERC4626 vault1;
    uint64 minDepositBlocks;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`sqrtPriceX96`|`uint160`|        Initial sqrt price (Q64.96) for the v4 pool.|
|`distribution`|`LiquidityBucket[]`|        Liquidity distribution buckets (weights must sum to 10_000).|
|`allowExternalDeposits`|`bool`|Whether non-owner addresses may call `addLiquidity`.|
|`vault0`|`IERC4626`|              ERC4626 vault for currency0 (address(0) to hold as ERC-20).|
|`vault1`|`IERC4626`|              ERC4626 vault for currency1 (address(0) to hold as ERC-20).|
|`minDepositBlocks`|`uint64`|    Per-pool deposit lock duration. `0` (default) means no lock and same-block deposit-then-withdraw is allowed. Must be `<= maxMinDepositBlocks`. Immutable after `initializePool`.|

