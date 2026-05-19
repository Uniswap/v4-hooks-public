# SmartPoolHook
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0a317c27dcab11b55acb839bccd006c6ffa8744c/src/alf/SmartPoolHook.sol)

**Inherits:**
[SmartPoolBase](/src/alf/base/SmartPoolBase.sol/abstract.SmartPoolBase.md), [PoolVault](/src/alf/base/PoolVault.sol/abstract.PoolVault.md), [JITLockable](/src/alf/base/JITLockable.sol/abstract.JITLockable.md), ReentrancyGuardTransient

**Title:**
SmartPoolHook

**Author:**
Uniswap Labs

JIT quoter with ERC4626 vault rehypothecation and multi-range liquidity
distribution. Pricing is fully static — pool fees are set at deploy time via
`PoolKey.fee` and never change.
Assets are deployed across multiple tick ranges ("buckets") during each JIT cycle,
with owner-configured weights that control capital concentration. Token allocation
across buckets uses `getLiquidityForAmounts` at the current price so that no capital
sits idle — even when the price has drifted and ranges are asymmetric.
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
hook intentionally **ignores hookData on swaps**.
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
are not eligible for that guard (no fresh entry point), so they manage a separate
`JIT_LOCK` transient slot and the LP entries reject calls while it is set. This
blocks an owner-configured ERC4626 vault from re-entering LP entry points mid-JIT.

**Note:**
security-contact: security@uniswap.org


## State Variables
### LP_SALT
Salt for the hook's LP positions in the PoolManager, distinguishing them
from positions created by other hooks or LPs on the same pool.


```solidity
bytes32 private constant LP_SALT = bytes32(uint256(0x534D5254))
```


### MAX_BUCKETS
Maximum number of buckets per pool. Bounds gas cost of the JIT cycle:
each bucket requires one modifyLiquidity call to deploy and one to remove,
so gas scales linearly with bucket count.


```solidity
uint8 private constant MAX_BUCKETS = 8
```


### _ACTIVE_LIQ_NAMESPACE
Transient namespace for active per-bucket JIT liquidity. The slot for bucket `i`
of pool `poolId` is `keccak256(_ACTIVE_LIQ_NAMESPACE, poolId) + i`. Lives only for
the duration of a swap callback pair (`_beforeSwap` deploys, `_afterSwap` removes),
so transient storage is the natural fit — avoids the cold/warm SSTORE penalty
(~22K cold, ~5K warm) per bucket that storage-backed tracking incurs.


```solidity
bytes32 private constant _ACTIVE_LIQ_NAMESPACE = keccak256("smartpoolhook.activeliq.v1")
```


### externalDepositsEnabled
Whether non-owner addresses may deposit into a pool.


```solidity
mapping(PoolId => bool) public externalDepositsEnabled
```


### _distribution
Liquidity distribution per pool. Each entry defines a tick range and its weight.
Set at initialization via `initializePool`, updatable via `setDistribution`.


```solidity
mapping(PoolId => LiquidityBucket[]) internal _distribution
```


## Functions
### constructor


```solidity
constructor(IPoolManager _pm, uint32 maxGas_, address owner_) SmartPoolBase(_pm, maxGas_, owner_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pm`|`IPoolManager`|    The Uniswap v4 PoolManager.|
|`maxGas_`|`uint32`|Gas budget declared for `getIndicativeQuote` staticcalls.|
|`owner_`|`address`| Immutable contract owner. Cannot be changed post-deployment; key loss or compromise is unrecoverable. See {SmartPoolBase}.|


### initializePool

Initialize a new pool with vaults and liquidity distribution.

Calls `poolManager.initialize` internally. The pool's LP fee is taken from
`key.fee` and is static — it cannot be changed post-deployment. Vaults are
permanent — set at creation and cannot be changed. The distribution can be
updated later via `setDistribution`.
Native ETH (currency `address(0)`) is rejected — wrap as WETH instead.
The pool is initialized as live; toggle via `setPoolLive` for emergency pause.
The pool is **not seeded** by `initializePool`; the owner must call `bootstrap`
to mint the first shares before any swaps or external deposits can occur.


```solidity
function initializePool(PoolKey calldata key, PoolConfig calldata config) external onlyOwner returns (int24 tick);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|   The PoolKey (must reference this hook). `key.fee` is the static LP fee.|
|`config`|`PoolConfig`|Pool configuration including distribution, vaults, and permissions.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tick`|`int24`| The initial tick assigned by the PoolManager.|


### bootstrap

Seed a pool with the first deposit. Mints `sqrt(amount0 * amount1)` shares
to the owner.

Only the owner may bootstrap. The owner-supplied amounts set the initial
share/asset ratio, which is critical for asymmetric-decimal pairs (e.g.,
USDC/WETH) where a naïve 1-wei-of-each bootstrap would either be unaffordable
or set a meaningless price. Inflation defense is provided by virtual-shares
offsets in the conversion math (see {PoolVault._convertToAmounts}). Reverts
if the pool is already bootstrapped or if `sqrt(amount0 * amount1) == 0`.


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
) external nonReentrant whenJITNotInProgress returns (uint256 amount0, uint256 amount1);
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
) external nonReentrant whenJITNotInProgress returns (uint256 amount0, uint256 amount1);
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
Zeroes the existing allowance first (USDT-safe) before re-approving to
`type(uint256).max`. No-op if the pool has no vault configured for `currency`.


```solidity
function refreshVaultApproval(PoolKey calldata key, Currency currency) external onlyOwner whenJITNotInProgress;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|     The pool whose vault allowance should be refreshed.|
|`currency`|`Currency`|Which side (currency0 or currency1) to refresh.|


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


### setActiveTick

Disabled: SmartPool uses distribution buckets instead of one active LP tick.

Always reverts with [SetActiveTickDisabled](/src/alf/SmartPoolHook.sol/contract.SmartPoolHook.md#setactivetickdisabled). The function exists only to satisfy
the inherited interface; SmartPool routes liquidity through [setDistribution](/src/alf/SmartPoolHook.sol/contract.SmartPoolHook.md#setdistribution)
instead. Marked `pure` because no state is read or written.


```solidity
function setActiveTick(PoolKey calldata, int24) external pure;
```

### setPoolLive

Enable or disable pool liveness for emergency pause/resume.

When toggled to false, `_beforeSwap` reverts with [PoolNotLive](/src/alf/SmartPoolHook.sol/contract.SmartPoolHook.md#poolnotlive), pausing the
pool for swaps. The static fee (`key.fee`) is unaffected — re-enabling
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

Caps vault-side balance at `vault.maxWithdraw(this)` so paused, capped, or
utilization-constrained vaults are reflected.


```solidity
function getEffectiveLiquidity(PoolKey calldata key)
    external
    view
    override
    returns (uint256 token0, uint256 token1);
```

### getIndicativeQuote

Indicative quote against hypothetical SmartPool JIT liquidity.

Uses current active distribution-bucket liquidity for a compact view quote.
Ignores hookData; pricing is the static `key.fee`.


```solidity
function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
    external
    view
    override
    returns (uint256 outputAmount);
```

### swapToPrice

Simulate a price-bounded swap against hypothetical JIT liquidity.


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
reaches this body is an external `modifyLiquidity` call -- always reject.


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
the static `key.fee` on the in-flight swap natively — no override is returned.
Reverts when the pool is paused (`!live`). Routers and aggregators see an explicit
failure instead of the swap running against zero deployed liquidity; the
multiplexer's per-target try/catch already handles the revert. hookData is
ignored entirely (see contract-level NatSpec).
A reentrant `_beforeSwap` on the same pool (e.g., from a malicious vault calling
`poolManager.swap(samePool)` during `_withdrawFromVault`) would corrupt the JIT
lifecycle: the inner `_clearJITLock` would zero the per-pool slot while the outer
cycle is still in flight, so the outer `_afterSwap` would short-circuit and leave
the outer's deployed positions orphaned. Reject up-front.


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
set; a defensive `_isJITLocked` read is unnecessary.


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
hook's global `IERC20.balanceOf` — preserving cross-pool isolation when the
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


### _computeAllocations

Compute weighted liquidity per bucket and total token needs.
Loads distribution from storage once, caches sqrtPrices to avoid
redundant getSqrtPriceAtTick calls (~500 gas each).


```solidity
function _computeAllocations(
    LiquidityBucket[] storage dist,
    uint256 n,
    uint160 sqrtPriceX96,
    uint256 bal0,
    uint256 bal1
) private view returns (uint128[MAX_BUCKETS] memory liqs, uint256 totalNeed0, uint256 totalNeed1);
```

### _deployBuckets

Deploy each bucket's LP position. Separated from _deployJIT for stack depth.
Records each deployed liquidity value in transient storage (slot = base + i)
so `_removeJIT` can size its inverse `modifyLiquidity` call without a storage SLOAD.


```solidity
function _deployBuckets(
    PoolId poolId,
    PoolKey calldata key,
    LiquidityBucket[] storage dist,
    uint256 n,
    uint128[MAX_BUCKETS] memory liqs
) private;
```

### _removeJIT

Remove all active JIT positions deployed in `_deployJIT`. Iterates the distribution
and removes each bucket that has non-zero active liquidity (read from transient
storage). After removal, the hook's cumulative delta reflects the net position from
the deploy-swap-remove cycle. Transient slots auto-clear at end of transaction, so
we don't bother zeroing them — saves a TSTORE per bucket.


```solidity
function _removeJIT(PoolId poolId, PoolKey calldata key) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to remove JIT positions from.|
|`key`|`PoolKey`|   The pool key (for modifyLiquidity calls).|


### _resolveNetDelta

Resolve the hook's net delta for both currencies after the JIT cycle.
Negative delta (hook owes PM): settle from per-pool ERC-20.
Positive delta (PM owes hook): mint as ERC-6909 claims — cannot `take` because
the swapper hasn't settled yet. Claims are redeemed in the next `_deployJIT`.


```solidity
function _resolveNetDelta(PoolId poolId, PoolKey calldata key) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to resolve deltas for (used for claim tracking).|
|`key`|`PoolKey`|   The pool key (for currency references).|


### _resolveNetDeltaCurrency

Resolve the hook's net delta for a single currency. Updates per-pool ERC-20
tracking on settle so that `_erc20[poolId][currency]` continues to reflect the
pool's share of the hook's actual token balance.


```solidity
function _resolveNetDeltaCurrency(PoolId poolId, Currency currency) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|  The pool (for per-pool claim recording).|
|`currency`|`Currency`|The currency to resolve.|


### _setDistribution

Validate and store a liquidity distribution. Enforces:
- 1 to MAX_BUCKETS entries
- All ticks aligned to tickSpacing
- All tick ranges valid (lower < upper)
- No zero-weight buckets
- Weights sum to exactly 10_000


```solidity
function _setDistribution(PoolId poolId, LiquidityBucket[] calldata buckets, int24 tickSpacing) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|     The pool to configure.|
|`buckets`|`LiquidityBucket[]`|    The distribution buckets to validate and store.|
|`tickSpacing`|`int24`|The pool's tick spacing (for alignment validation).|


### _simulateIndicative


```solidity
function _simulateIndicative(
    PoolKey calldata key,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96
) internal view returns (uint256 amountIn, uint256 amountOut);
```

### _composeEffectiveFee


```solidity
function _composeEffectiveFee(uint24 lpFee, uint24 protocolFee, bool zeroForOne) private pure returns (uint24);
```

### _activeIndicativeLiquidity


```solidity
function _activeIndicativeLiquidity(
    PoolId poolId,
    uint160 sqrtPriceX96,
    int24 currentTick,
    uint256 bal0,
    uint256 bal1
) internal view returns (uint128 liquidity);
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
for `address(0)` (no vault — currency held as raw ERC-20). Called only at
`initializePool` since the vault address is immutable thereafter.


```solidity
function _requireVaultMatchesCurrency(IERC4626 vault, Currency currency) internal view;
```

### _poolManager

Provides PoolVault access to the PoolManager for claim operations (burn/take).


```solidity
function _poolManager() internal view override returns (IPoolManager);
```

### _activeLiqBase

Base transient slot for the active-liquidity array of `poolId`. Per-bucket
slots are derived as `base + bucketIndex`. Single keccak per JIT cycle, then
pure addition for each bucket access.


```solidity
function _activeLiqBase(PoolId poolId) private pure returns (bytes32);
```

## Events
### PoolCreated
Emitted when a new pool is initialized via `initializePool`.


```solidity
event PoolCreated(PoolId indexed poolId);
```

### DistributionUpdated
Emitted when the liquidity distribution is replaced via `setDistribution`.


```solidity
event DistributionUpdated(PoolId indexed poolId);
```

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

### InvalidDistribution
Distribution is invalid: empty, exceeds MAX_BUCKETS, weights don't sum to 10_000,
or a bucket has zero weight.


```solidity
error InvalidDistribution();
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

### SetActiveTickDisabled
`setActiveTick` is disabled on SmartPool. The hook routes liquidity through
distribution buckets, not a single active tick. Use [setDistribution](/src/alf/SmartPoolHook.sol/contract.SmartPoolHook.md#setdistribution) instead.


```solidity
error SetActiveTickDisabled();
```

### Unauthorized
Caller is not authorized for this entry point. Used by `_requireDepositAuth`
and `_beforeInitialize`. Owner gating is handled by OZ Ownable's
`OwnableUnauthorizedAccount`.


```solidity
error Unauthorized();
```

### PoolNotLive
`_beforeSwap` was invoked on a pool whose `live` flag is false. Owner pauses
the pool via [setPoolLive](/src/alf/SmartPoolHook.sol/contract.SmartPoolHook.md#setpoollive); while paused, swaps revert here so routers and
aggregators see an explicit failure instead of executing against zero JIT
liquidity.


```solidity
error PoolNotLive(PoolId poolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose live flag is currently false.|

## Structs
### LiquidityBucket
A tick range with a weight for liquidity distribution.


```solidity
struct LiquidityBucket {
    int24 tickLower;
    int24 tickUpper;
    uint16 weightBps;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`tickLower`|`int24`|Lower tick boundary (must be aligned to pool's tickSpacing).|
|`tickUpper`|`int24`|Upper tick boundary (must be aligned to pool's tickSpacing).|
|`weightBps`|`uint16`|Fraction of total capital allocated to this range, in basis points. All weights across a pool's distribution must sum to 10_000.|

### PoolConfig
Configuration for initializing a new pool. Passed to `initializePool`.


```solidity
struct PoolConfig {
    uint160 sqrtPriceX96;
    LiquidityBucket[] distribution;
    bool allowExternalDeposits;
    IERC4626 vault0;
    IERC4626 vault1;
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

