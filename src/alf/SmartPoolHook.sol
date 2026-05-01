// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SmartPoolBase} from "./base/SmartPoolBase.sol";
import {JITLockable} from "./base/JITLockable.sol";
import {PoolVault} from "./base/PoolVault.sol";

/// @title SmartPoolHook
/// @author Uniswap Labs
/// @notice JIT quoter with ERC4626 vault rehypothecation and multi-range liquidity
///         distribution. Pricing is fully static — pool fees are set at deploy time via
///         `PoolKey.fee` and never change.
///
///         Assets are deployed across multiple tick ranges ("buckets") during each JIT cycle,
///         with owner-configured weights that control capital concentration. Token allocation
///         across buckets uses `getLiquidityForAmounts` at the current price so that no capital
///         sits idle — even when the price has drifted and ranges are asymmetric.
///
///         Example: 75% at [-10,10], 15% at [-30,30], 10% at [-60,60] concentrates most
///         liquidity around the peg while maintaining depth for larger price moves.
///
///         ## JIT Lifecycle
///
///           beforeSwap:
///             1. Set the JIT lock (blocks reentrant addLiquidity/removeLiquidity/setDistribution)
///             2. Compute per-bucket liquidity from current assets and weights
///             3. Compute exact token amounts needed via SqrtPriceMath
///             4. Redeem claims, withdraw only the shortfall from vaults
///             5. Deploy each bucket as a concentrated LP position
///
///           [pool executes swap against the deployed LP with fee override]
///
///           afterSwap:
///             1. Remove all bucket positions
///             2. Settle net deltas (negative → ERC-20 to PM, positive → mint claims),
///                debiting per-pool ERC-20 tracking on settle
///             3. Re-deposit remaining per-pool ERC-20 to vaults
///             4. Clear the JIT lock
///
///         ## Pricing
///
///         The pool's LP fee is read from `PoolKey.fee` and charged natively by v4 on every
///         swap. The fee is fixed at pool-creation time and cannot be changed afterwards. The
///         owner has only a per-pool liveness flag (`setPoolLive`) for emergency pause; the
///         hook intentionally **ignores hookData on swaps**.
///
///         ## Share Accounting
///
///         Inherited from PoolVault. Pools are seeded by the owner via `bootstrap`, which mints
///         `sqrt(amount0 * amount1)` shares (Uniswap V2 style). Inflation defense uses
///         EIP-4626 virtual-shares offsets in the conversion math (see PoolVault). After
///         bootstrap, anyone with deposit auth may call `addLiquidity` for proportional
///         shares. LPs hold proportional shares of the pool's total assets (vault shares +
///         claims + per-pool ERC-20).
///
///         ## Reentrancy
///
///         User-facing entry points (`bootstrap`, `addLiquidity`, `removeLiquidity`) carry the
///         OZ `nonReentrant` transient guard. PM-driven callbacks (`_beforeSwap`, `_afterSwap`)
///         are not eligible for that guard (no fresh entry point), so they manage a separate
///         `JIT_LOCK` transient slot and the LP entries reject calls while it is set. This
///         blocks an owner-configured ERC4626 vault from re-entering LP entry points mid-JIT.
/// @custom:security-contact security@uniswap.org
contract SmartPoolHook is SmartPoolBase, PoolVault, JITLockable, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;
    using SafeERC20 for IERC20;
    /// @notice Salt for the hook's LP positions in the PoolManager, distinguishing them
    ///         from positions created by other hooks or LPs on the same pool.
    bytes32 private constant LP_SALT = bytes32(uint256(0x534D5254)); // "SMRT"

    /// @notice Maximum number of buckets per pool. Bounds gas cost of the JIT cycle:
    ///         each bucket requires one modifyLiquidity call to deploy and one to remove,
    ///         so gas scales linearly with bucket count.
    uint8 private constant MAX_BUCKETS = 8;

    /// @dev Transient namespace for active per-bucket JIT liquidity. The slot for bucket `i`
    ///      of pool `poolId` is `keccak256(_ACTIVE_LIQ_NAMESPACE, poolId) + i`. Lives only for
    ///      the duration of a swap callback pair (`_beforeSwap` deploys, `_afterSwap` removes),
    ///      so transient storage is the natural fit — avoids the cold/warm SSTORE penalty
    ///      (~22K cold, ~5K warm) per bucket that storage-backed tracking incurs.
    bytes32 private constant _ACTIVE_LIQ_NAMESPACE = keccak256("smartpoolhook.activeliq.v1");

    // ═══════════════════════════════════════════════════════════════════════════
    //                              TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A tick range with a weight for liquidity distribution.
    /// @param tickLower Lower tick boundary (must be aligned to pool's tickSpacing).
    /// @param tickUpper Upper tick boundary (must be aligned to pool's tickSpacing).
    /// @param weightBps Fraction of total capital allocated to this range, in basis points.
    ///                  All weights across a pool's distribution must sum to 10_000.
    struct LiquidityBucket {
        int24 tickLower;
        int24 tickUpper;
        uint16 weightBps;
    }

    /// @notice Configuration for initializing a new pool. Passed to `initializePool`.
    /// @param sqrtPriceX96         Initial sqrt price (Q64.96) for the v4 pool.
    /// @param distribution         Liquidity distribution buckets (weights must sum to 10_000).
    /// @param allowExternalDeposits Whether non-owner addresses may call `addLiquidity`.
    /// @param vault0               ERC4626 vault for currency0 (address(0) to hold as ERC-20).
    /// @param vault1               ERC4626 vault for currency1 (address(0) to hold as ERC-20).
    struct PoolConfig {
        uint160 sqrtPriceX96;
        LiquidityBucket[] distribution;
        bool allowExternalDeposits;
        IERC4626 vault0;
        IERC4626 vault1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Whether non-owner addresses may deposit into a pool.
    mapping(PoolId => bool) public externalDepositsEnabled;

    /// @dev Liquidity distribution per pool. Each entry defines a tick range and its weight.
    ///      Set at initialization via `initializePool`, updatable via `setDistribution`.
    mapping(PoolId => LiquidityBucket[]) internal _distribution;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new pool is initialized via `initializePool`.
    event PoolCreated(PoolId indexed poolId);

    /// @notice Emitted when the liquidity distribution is replaced via `setDistribution`.
    event DistributionUpdated(PoolId indexed poolId);

    // ═══════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev External address attempted to add or remove v4 pool liquidity directly.
    ///      Only the hook itself may modify LP positions (during JIT cycles).
    error LiquidityNotAllowed();

    /// @dev The PoolKey's hooks address does not match this contract.
    error InvalidHookAddress();

    /// @dev Distribution is invalid: empty, exceeds MAX_BUCKETS, weights don't sum to 10_000,
    ///      or a bucket has zero weight.
    error InvalidDistribution();

    /// @dev Pool initialization rejected because one of the currencies is native ETH
    ///      (`address(0)`). PoolVault uses `IERC20.safeTransferFrom` which cannot operate on
    ///      `address(0)`, and the hook lacks a `receive() payable` function. Operators must
    ///      use a wrapped-ETH variant (e.g., WETH9) instead.
    error NativeNotSupported();

    /// @dev Configured ERC-4626 vault's `asset()` does not match the pool's currency. Vault
    ///      addresses are immutable post-init, so this fails fast instead of producing a
    ///      pool that silently mis-accounts.
    error VaultAssetMismatch();

    /// @dev `block.timestamp` exceeded the caller-supplied `deadline` for an LP operation.
    error DeadlineExpired();

    /// @dev `addLiquidity` would have transferred more than `maxAmount0`/`maxAmount1` from the
    ///      caller, or `removeLiquidity` would have transferred less than
    ///      `minAmount0`/`minAmount1` to the caller. Caller's slippage bounds were violated.
    error SlippageExceeded();

    /// @dev `setActiveTick` is disabled on SmartPool. The hook routes liquidity through
    ///      distribution buckets, not a single active tick. Use {setDistribution} instead.
    error SetActiveTickDisabled();

    /// @dev Caller is not authorized for this entry point. Used by `_requireDepositAuth`
    ///      and `_beforeInitialize`. Owner gating is handled by OZ Ownable's
    ///      `OwnableUnauthorizedAccount`.
    error Unauthorized();

    /// @dev `_beforeSwap` was invoked on a pool whose `live` flag is false. Owner pauses
    ///      the pool via {setPoolLive}; while paused, swaps revert here so routers and
    ///      aggregators see an explicit failure instead of executing against zero JIT
    ///      liquidity.
    /// @param poolId The pool whose live flag is currently false.
    error PoolNotLive(PoolId poolId);

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _pm     The Uniswap v4 PoolManager.
    /// @param maxGas_ Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_  Immutable contract owner. Cannot be changed post-deployment;
    ///                key loss or compromise is unrecoverable. See {SmartPoolBase}.
    constructor(
        IPoolManager _pm,
        uint32 maxGas_,
        address owner_
    ) SmartPoolBase(_pm, maxGas_, owner_) {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool with vaults and liquidity distribution.
    /// @dev    Calls `poolManager.initialize` internally. The pool's LP fee is taken from
    ///         `key.fee` and is static — it cannot be changed post-deployment. Vaults are
    ///         permanent — set at creation and cannot be changed. The distribution can be
    ///         updated later via `setDistribution`.
    ///         Native ETH (currency `address(0)`) is rejected — wrap as WETH instead.
    ///         The pool is initialized as live; toggle via `setPoolLive` for emergency pause.
    ///         The pool is **not seeded** by `initializePool`; the owner must call `bootstrap`
    ///         to mint the first shares before any swaps or external deposits can occur.
    /// @param key    The PoolKey (must reference this hook). `key.fee` is the static LP fee.
    /// @param config Pool configuration including distribution, vaults, and permissions.
    /// @return tick  The initial tick assigned by the PoolManager.
    function initializePool(PoolKey calldata key, PoolConfig calldata config)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeNotSupported();

        // Vaults are immutable per (pool, currency) post-init. Verify the configured ERC-4626
        // vault wraps the same underlying as the currency before storing — a mismatch would
        // otherwise brick bootstrap/deposit/swap silently or, worse, account shares against an
        // unexpected underlying.
        _requireVaultMatchesCurrency(config.vault0, key.currency0);
        _requireVaultMatchesCurrency(config.vault1, key.currency1);

        PoolId poolId = key.toId();
        externalDepositsEnabled[poolId] = config.allowExternalDeposits;
        vaults[poolId][key.currency0] = config.vault0;
        vaults[poolId][key.currency1] = config.vault1;

        // Approve once at init time so JIT-cycle vault deposits can skip the runtime
        // allowance read. Allowance set to `type(uint256).max` is never decremented by
        // `vault.deposit`, so a single approval is durable for the (currency, vault) pair.
        // Vault-trust trade-off: see PoolVault `_depositToVault` NatSpec and K-05.
        _approveVault(key.currency0, address(config.vault0));
        _approveVault(key.currency1, address(config.vault1));

        _setDistribution(poolId, config.distribution, key.tickSpacing);

        tick = poolManager.initialize(key, config.sqrtPriceX96);
        livePools[poolId] = true;
        emit PoolLivenessUpdated(poolId, true);
        emit PoolCreated(poolId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: LP DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Seed a pool with the first deposit. Mints `sqrt(amount0 * amount1)` shares
    ///         to the owner.
    /// @dev    Only the owner may bootstrap. The owner-supplied amounts set the initial
    ///         share/asset ratio, which is critical for asymmetric-decimal pairs (e.g.,
    ///         USDC/WETH) where a naïve 1-wei-of-each bootstrap would either be unaffordable
    ///         or set a meaningless price. Inflation defense is provided by virtual-shares
    ///         offsets in the conversion math (see {PoolVault._convertToAmounts}). Reverts
    ///         if the pool is already bootstrapped or if `sqrt(amount0 * amount1) == 0`.
    /// @param key     The pool to bootstrap.
    /// @param amount0 Currency0 to deposit.
    /// @param amount1 Currency1 to deposit.
    /// @return shares Total shares minted, all credited to the owner.
    function bootstrap(PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        onlyOwner
        nonReentrant
        whenJITNotInProgress
        returns (uint256 shares)
    {
        return _bootstrap(key, msg.sender, msg.sender, amount0, amount1);
    }

    /// @notice Deposit token0 and token1 proportional to the pool's current asset ratio.
    /// @dev    Requires owner or external deposits enabled. Pool must be bootstrapped first.
    ///         Records the depositor's deposit block; `removeLiquidity` reverts in the same
    ///         block to defend against atomic deposit-swap-withdraw fee/yield sniping.
    ///
    ///         Slippage bounds are enforced after the actual transfers so callers cap exposure
    ///         to swaps, vault share-price moves, or MEV between off-chain `previewDeposit` and
    ///         on-chain inclusion. `deadline` MUST be `>= block.timestamp` or the call reverts.
    ///         Use `type(uint256).max` for unbounded values, but production callers SHOULD set
    ///         tight bounds.
    /// @param key          The pool to deposit into.
    /// @param sharesToMint Number of shares to mint. Use `previewDeposit` to see required amounts.
    /// @param maxAmount0   Maximum currency0 the caller is willing to spend. Reverts if exceeded.
    /// @param maxAmount1   Maximum currency1 the caller is willing to spend. Reverts if exceeded.
    /// @param deadline     Unix timestamp after which the call reverts.
    /// @return amount0     Actual currency0 transferred from the caller.
    /// @return amount1     Actual currency1 transferred from the caller.
    function addLiquidity(
        PoolKey calldata key,
        uint256 sharesToMint,
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint256 deadline
    )
        external
        nonReentrant
        whenJITNotInProgress
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _requireDepositAuth(key.toId());
        (amount0, amount1) = _deposit(key, msg.sender, msg.sender, sharesToMint);
        if (amount0 > maxAmount0 || amount1 > maxAmount1) revert SlippageExceeded();
    }

    /// @notice Burn shares and receive proportional token0 + token1.
    /// @dev    Amounts are rounded down to prevent over-withdrawal. Tokens are withdrawn
    ///         from vaults via `vault.withdraw` (exact assets) if the pool's tracked ERC-20
    ///         is insufficient. Reverts in the same block as the depositor's last deposit
    ///         (anti-fee-sniping).
    ///
    ///         Slippage bounds are enforced after the actual transfers so callers floor
    ///         received amounts against pool ratio moves between preview and inclusion.
    ///         `deadline` MUST be `>= block.timestamp` or the call reverts.
    /// @param key          The pool to withdraw from.
    /// @param sharesToBurn Number of shares to burn. Use `previewWithdraw` to see return amounts.
    /// @param minAmount0   Minimum currency0 the caller will accept. Reverts if not met.
    /// @param minAmount1   Minimum currency1 the caller will accept. Reverts if not met.
    /// @param deadline     Unix timestamp after which the call reverts.
    /// @return amount0     Actual currency0 transferred to the caller.
    /// @return amount1     Actual currency1 transferred to the caller.
    function removeLiquidity(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 deadline
    )
        external
        nonReentrant
        whenJITNotInProgress
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        (amount0, amount1) = _withdraw(key, msg.sender, msg.sender, sharesToBurn);
        if (amount0 < minAmount0 || amount1 < minAmount1) revert SlippageExceeded();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: OWNER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Replace the liquidity distribution for a pool.
    /// @dev    Weights must sum to 10_000. Ticks must be aligned to tickSpacing.
    ///         Buckets can be asymmetric, overlapping, or non-contiguous.
    ///         Reverts during an active JIT cycle to prevent orphaning live LP positions.
    /// @param key     The pool to update.
    /// @param buckets The new distribution (1 to MAX_BUCKETS entries).
    function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets)
        external
        onlyOwner
        whenJITNotInProgress
    {
        _setDistribution(key.toId(), buckets, key.tickSpacing);
        emit DistributionUpdated(key.toId());
    }

    /// @notice Refresh the max-approval the hook grants to a pool's ERC-4626 vault.
    /// @dev    Recovery path for vaults whose allowance is unexpectedly consumed or reset.
    ///         Zeroes the existing allowance first (USDT-safe) before re-approving to
    ///         `type(uint256).max`. No-op if the pool has no vault configured for `currency`.
    /// @param key      The pool whose vault allowance should be refreshed.
    /// @param currency Which side (currency0 or currency1) to refresh.
    function refreshVaultApproval(PoolKey calldata key, Currency currency)
        external
        onlyOwner
        whenJITNotInProgress
    {
        IERC4626 vault = vaults[key.toId()][currency];
        if (address(vault) == address(0)) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        token.forceApprove(address(vault), 0);
        token.forceApprove(address(vault), type(uint256).max);
    }

    /// @notice Enable or disable external (non-owner) deposits for a pool.
    /// @param key     The pool to configure.
    /// @param enabled True to permit non-owner `addLiquidity`, false for owner-only.
    function setExternalDeposits(PoolKey calldata key, bool enabled)
        external
        onlyOwner
        whenJITNotInProgress
    {
        externalDepositsEnabled[key.toId()] = enabled;
    }

    /// @notice Disabled: SmartPool uses distribution buckets instead of one active LP tick.
    /// @dev    Always reverts with {SetActiveTickDisabled}. The function exists only to satisfy
    ///         the inherited interface; SmartPool routes liquidity through {setDistribution}
    ///         instead. Marked `pure` because no state is read or written.
    function setActiveTick(PoolKey calldata, int24) external pure {
        revert SetActiveTickDisabled();
    }

    /// @notice Enable or disable pool liveness for emergency pause/resume.
    /// @dev    When toggled to false, `_beforeSwap` reverts with {PoolNotLive}, pausing the
    ///         pool for swaps. The static fee (`key.fee`) is unaffected — re-enabling
    ///         immediately restores trading at the original rate.
    /// @param key  The pool to toggle.
    /// @param live True to make swaps execute against JIT liquidity, false to pause the pool.
    function setPoolLive(PoolKey calldata key, bool live)
        external
        onlyOwner
        whenJITNotInProgress
    {
        livePools[key.toId()] = live;
        emit PoolLivenessUpdated(key.toId(), live);
    }

    /// @notice Total reserves managed by this hook for the given pool.
    /// @dev    Includes ERC-20, ERC-6909 claims, and ERC4626 vault balances.
    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _totalAssets(key);
    }

    /// @notice Assets available for immediate swapping.
    /// @dev    Caps vault-side balance at `vault.maxWithdraw(this)` so paused, capped, or
    ///         utilization-constrained vaults are reflected.
    function getEffectiveLiquidity(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _effectiveAssets(key);
    }

    /// @notice Indicative quote against hypothetical SmartPool JIT liquidity.
    /// @dev    Uses current active distribution-bucket liquidity for a compact view quote.
    ///         Ignores hookData; pricing is the static `key.fee`.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (uint256 amountIn, uint256 amountOut) = _simulateIndicative(key, zeroForOne, amountSpecified, limit);
        outputAmount = amountSpecified < 0 ? amountOut : amountIn;
    }

    /// @notice Simulate a price-bounded swap against hypothetical JIT liquidity.
    function swapToPrice(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        view
        override
        returns (uint256 amountIn, uint256 amountOut)
    {
        return _simulateIndicative(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    /// @notice Returns the share balance of `user` for the given pool.
    /// @param key  The pool whose share balance to read.
    /// @param user The address whose shares to look up.
    /// @return The number of pool shares held by `user`.
    function sharesOf(PoolKey calldata key, address user) external view returns (uint256) {
        return _userShares[_vaultIdFor(key.toId())][user];
    }

    /// @notice Returns the current liquidity distribution for a pool.
    /// @param poolId The pool to query.
    /// @return The active list of liquidity buckets (tick ranges + weights).
    function getDistribution(PoolId poolId) external view returns (LiquidityBucket[] memory) {
        return _distribution[poolId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        PUBLIC: HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Required v4 hook flags:
    ///      - beforeInitialize: block direct init (force initializePool)
    ///      - beforeAddLiquidity / beforeRemoveLiquidity: restrict to hook-only LP
    ///      - beforeSwap: JIT deployment + fee override
    ///      - afterSwap: JIT teardown + delta resolution
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev External LP additions are blocked. v4-core's `Hooks.noSelfCall` skips the hook
    ///      callback entirely when the hook itself is the caller, so the only path that
    ///      reaches this body is an external `modifyLiquidity` call -- always reject.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal pure override returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev External LP removals are blocked. Same `noSelfCall` reasoning as `_beforeAddLiquidity`.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal pure override returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev JIT entry point. Deploys multi-range JIT liquidity under the JIT lock. v4 charges
    ///      the static `key.fee` on the in-flight swap natively — no override is returned.
    ///
    ///      Reverts when the pool is paused (`!live`). Routers and aggregators see an explicit
    ///      failure instead of the swap running against zero deployed liquidity; the
    ///      multiplexer's per-target try/catch already handles the revert. hookData is
    ///      ignored entirely (see contract-level NatSpec).
    ///
    ///      A reentrant `_beforeSwap` on the same pool (e.g., from a malicious vault calling
    ///      `poolManager.swap(samePool)` during `_withdrawFromVault`) would corrupt the JIT
    ///      lifecycle: the inner `_clearJITLock` would zero the per-pool slot while the outer
    ///      cycle is still in flight, so the outer `_afterSwap` would short-circuit and leave
    ///      the outer's deployed positions orphaned. Reject up-front.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        if (_isJITLocked(poolId)) revert JITInProgress();
        if (!livePools[poolId]) revert PoolNotLive(poolId);

        _setJITLock(poolId);
        _deployJIT(poolId, key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev JIT teardown. Removes all bucket positions, resolves the hook's net delta for both
    ///      currencies (debiting per-pool ERC-20 on settle), re-deposits remaining ERC-20 to
    ///      vaults, and clears the JIT lock. `_beforeSwap` always sets the lock when the pool
    ///      is live and reverts when it isn't, so reaching `_afterSwap` implies the lock is
    ///      set; a defensive `_isJITLocked` read is unnecessary.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal override returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        _removeJIT(poolId, key);
        _resolveNetDelta(poolId, key);
        _depositAllToVaults(poolId, key);
        _clearJITLock(poolId);
        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: JIT LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deploy JIT liquidity across all distribution buckets.
    ///
    ///      Three-phase strategy:
    ///        1. **Compute allocations**: for each bucket, compute its weighted liquidity
    ///           from the full balance via `getLiquidityForAmounts`, then use `SqrtPriceMath`
    ///           to determine the exact token0 and token1 needed for deployment.
    ///        2. **Targeted withdrawal**: redeem per-pool ERC-6909 claims first (cheaper
    ///           than vault interaction), then withdraw only the shortfall from vaults.
    ///           Unneeded capital stays in the vault earning yield during the swap window.
    ///           Phase 2 reads the pool's `_erc20[poolId][currency]` tracker rather than the
    ///           hook's global `IERC20.balanceOf` — preserving cross-pool isolation when the
    ///           hook serves multiple pools sharing a currency.
    ///        3. **Deploy**: add each bucket as a concentrated LP position.
    ///
    /// @param poolId The pool to deploy for.
    /// @param key    The pool key (for currency references and modifyLiquidity calls).
    function _deployJIT(PoolId poolId, PoolKey calldata key) internal {
        // Use the cap-aware view: vaults that report more assets via `convertToAssets` than they
        // can satisfy via `withdraw` (paused, capped, utilization-constrained) would otherwise
        // produce `liqs[]` and `totalNeed{0,1}` sized above what `_withdrawFromVault` can deliver,
        // and the `_deployBuckets` settle would revert mid-cycle. Sizing against `_effectiveAssets`
        // matches both `getEffectiveLiquidity` (the routing/aggregator view) and what the JIT
        // cycle can actually pay for at deploy time. Share math (`_convertToAmounts`) deliberately
        // continues to use `_totalAssets` per INV-POOL-12 — LP pro-rata claims are over true
        // economic stake, not the momentarily-withdrawable subset.
        (uint256 bal0, uint256 bal1) = _effectiveAssets(key);
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        LiquidityBucket[] storage distStorage = _distribution[poolId];
        uint256 n = distStorage.length;
        if (n == 0) return;

        // Phase 1: compute allocations. Loads distribution into memory and caches sqrtPrices.
        (uint128[] memory liqs, uint256 totalNeed0, uint256 totalNeed1) =
            _computeAllocations(distStorage, n, sqrtPriceX96, bal0, bal1);

        if (totalNeed0 == 0 && totalNeed1 == 0) return;

        // Phase 2: liquidate claims (cheap), then pull only the shortfall from vault.
        // `_redeemPoolClaims` returns the post-redeem per-pool ERC-20 balance so we avoid a
        // follow-up SLOAD. Per-pool tracking — NOT the hook's global balance — preserves
        // cross-pool isolation.
        uint256 onHand0 = _redeemPoolClaims(poolId, key.currency0);
        uint256 onHand1 = _redeemPoolClaims(poolId, key.currency1);
        if (totalNeed0 > onHand0) _withdrawFromVault(poolId, key.currency0, totalNeed0 - onHand0);
        if (totalNeed1 > onHand1) _withdrawFromVault(poolId, key.currency1, totalNeed1 - onHand1);

        // Phase 3: deploy each bucket.
        _deployBuckets(poolId, key, distStorage, n, liqs);
    }

    /// @dev Compute weighted liquidity per bucket and total token needs.
    ///      Loads distribution from storage once, caches sqrtPrices to avoid
    ///      redundant getSqrtPriceAtTick calls (~500 gas each).
    function _computeAllocations(
        LiquidityBucket[] storage dist,
        uint256 n,
        uint160 sqrtPriceX96,
        uint256 bal0,
        uint256 bal1
    ) private view returns (uint128[] memory liqs, uint256 totalNeed0, uint256 totalNeed1) {
        liqs = new uint128[](n);
        for (uint256 i; i < n; ++i) {
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(dist[i].tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(dist[i].tickUpper);

            // Pre-budget the bucket against its weighted share of the balance. The earlier
            // implementation passed the FULL `(bal0, bal1)` to `getLiquidityForAmounts` and
            // post-scaled by `weightBps / 10_000`. That over-counted capital across in-range
            // buckets — each bucket's `maxLiq` was sized for the entire balance, so the
            // summed liquidity (and indicative quote) overstated what the pool could actually
            // deploy. Pre-budgeting eliminates the implicit reuse and makes the indicative
            // path deterministic w.r.t. the JIT cycle's actual allocation.
            uint256 weightBps = dist[i].weightBps;
            uint256 weightedBal0 = bal0 * weightBps / 10_000;
            uint256 weightedBal1 = bal1 * weightBps / 10_000;
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtLower, sqrtUpper, weightedBal0, weightedBal1
            );
            liqs[i] = liq;

            if (liq > 0) {
                if (sqrtPriceX96 < sqrtUpper) {
                    uint160 upper = sqrtPriceX96 < sqrtLower ? sqrtLower : sqrtPriceX96;
                    totalNeed0 += SqrtPriceMath.getAmount0Delta(upper, sqrtUpper, liq, true);
                }
                if (sqrtPriceX96 > sqrtLower) {
                    uint160 lower = sqrtPriceX96 > sqrtUpper ? sqrtUpper : sqrtPriceX96;
                    totalNeed1 += SqrtPriceMath.getAmount1Delta(sqrtLower, lower, liq, true);
                }
            }
        }
    }

    /// @dev Deploy each bucket's LP position. Separated from _deployJIT for stack depth.
    ///      Records each deployed liquidity value in transient storage (slot = base + i)
    ///      so `_removeJIT` can size its inverse `modifyLiquidity` call without a storage SLOAD.
    function _deployBuckets(
        PoolId poolId,
        PoolKey calldata key,
        LiquidityBucket[] storage dist,
        uint256 n,
        uint128[] memory liqs
    ) private {
        bytes32 base = _activeLiqBase(poolId);
        for (uint256 i; i < n; ++i) {
            uint128 liq = liqs[i];
            if (liq > 0) {
                poolManager.modifyLiquidity(
                    key,
                    ModifyLiquidityParams({
                        tickLower: dist[i].tickLower,
                        tickUpper: dist[i].tickUpper,
                        liquidityDelta: int256(uint256(liq)),
                        salt: LP_SALT
                    }),
                    ""
                );
                bytes32 slot;
                unchecked { slot = bytes32(uint256(base) + i); }
                assembly ("memory-safe") {
                    tstore(slot, liq)
                }
            }
        }
    }

    /// @dev Remove all active JIT positions deployed in `_deployJIT`. Iterates the distribution
    ///      and removes each bucket that has non-zero active liquidity (read from transient
    ///      storage). After removal, the hook's cumulative delta reflects the net position from
    ///      the deploy-swap-remove cycle. Transient slots auto-clear at end of transaction, so
    ///      we don't bother zeroing them — saves a TSTORE per bucket.
    /// @param poolId The pool to remove JIT positions from.
    /// @param key    The pool key (for modifyLiquidity calls).
    function _removeJIT(PoolId poolId, PoolKey calldata key) internal {
        LiquidityBucket[] storage dist = _distribution[poolId];
        uint256 n = dist.length;
        bytes32 base = _activeLiqBase(poolId);

        for (uint256 i; i < n; ++i) {
            bytes32 slot;
            unchecked { slot = bytes32(uint256(base) + i); }
            uint128 liq;
            assembly ("memory-safe") {
                liq := tload(slot)
            }
            if (liq > 0) {
                poolManager.modifyLiquidity(
                    key,
                    ModifyLiquidityParams({
                        tickLower: dist[i].tickLower,
                        tickUpper: dist[i].tickUpper,
                        liquidityDelta: -int256(uint256(liq)),
                        salt: LP_SALT
                    }),
                    ""
                );
            }
        }
    }

    /// @dev Resolve the hook's net delta for both currencies after the JIT cycle.
    ///      Negative delta (hook owes PM): settle from per-pool ERC-20.
    ///      Positive delta (PM owes hook): mint as ERC-6909 claims — cannot `take` because
    ///      the swapper hasn't settled yet. Claims are redeemed in the next `_deployJIT`.
    /// @param poolId The pool to resolve deltas for (used for claim tracking).
    /// @param key    The pool key (for currency references).
    function _resolveNetDelta(PoolId poolId, PoolKey calldata key) internal {
        _resolveNetDeltaCurrency(poolId, key.currency0);
        _resolveNetDeltaCurrency(poolId, key.currency1);
    }

    /// @dev Resolve the hook's net delta for a single currency. Updates per-pool ERC-20
    ///      tracking on settle so that `_erc20[poolId][currency]` continues to reflect the
    ///      pool's share of the hook's actual token balance.
    /// @param poolId   The pool (for per-pool claim recording).
    /// @param currency The currency to resolve.
    function _resolveNetDeltaCurrency(PoolId poolId, Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            _settle(currency, address(this), owed);
            _debitPoolERC20(poolId, currency, owed);
        } else if (delta > 0) {
            uint256 amount = uint256(delta);
            poolManager.mint(address(this), currency.toId(), amount);
            _recordClaims(poolId, currency, amount);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: DISTRIBUTION MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Validate and store a liquidity distribution. Enforces:
    ///      - 1 to MAX_BUCKETS entries
    ///      - All ticks aligned to tickSpacing
    ///      - All tick ranges valid (lower < upper)
    ///      - No zero-weight buckets
    ///      - Weights sum to exactly 10_000
    /// @param poolId      The pool to configure.
    /// @param buckets     The distribution buckets to validate and store.
    /// @param tickSpacing The pool's tick spacing (for alignment validation).
    function _setDistribution(PoolId poolId, LiquidityBucket[] calldata buckets, int24 tickSpacing) internal {
        uint256 n = buckets.length;
        if (n == 0 || n > MAX_BUCKETS) revert InvalidDistribution();

        uint256 totalWeight;
        for (uint256 i; i < n; i++) {
            if (buckets[i].tickLower >= buckets[i].tickUpper) revert InvalidTickRange();
            // Reject ticks outside the v4 representable range — `TickMath.getSqrtPriceAtTick`
            // would otherwise revert later from inside allocation or quote paths,
            // bricking quotes and swaps for any pool with a misconfigured distribution.
            if (buckets[i].tickLower < TickMath.MIN_TICK || buckets[i].tickUpper > TickMath.MAX_TICK) {
                revert InvalidTickRange();
            }
            if (buckets[i].tickLower % tickSpacing != 0 || buckets[i].tickUpper % tickSpacing != 0) {
                revert InvalidTickRange();
            }
            if (buckets[i].weightBps == 0) revert InvalidDistribution();
            totalWeight += buckets[i].weightBps;
        }
        if (totalWeight != 10_000) revert InvalidDistribution();

        delete _distribution[poolId];

        for (uint256 i; i < n; i++) {
            _distribution[poolId].push(buckets[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: PRICING
    // ═══════════════════════════════════════════════════════════════════════════

    function _simulateIndicative(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        PoolId poolId = key.toId();

        if (!livePools[poolId]) return (0, 0);
        uint24 feePips = key.fee;

        // Use vault-cap-aware balances for indicative quotes. Execution caps vault
        // withdrawals at `maxWithdraw`, so quoting against the uncapped `_totalAssets`
        // produces an indicative the JIT cycle cannot honour when the vault is paused
        // or utilization-constrained. Share math (`_convertToAmounts`) deliberately uses
        // `_totalAssets` (uncapped) so LP pro-rata claims are not capped — see
        // INV-POOL-12 for the asymmetry rationale.
        (uint256 bal0, uint256 bal1) = _effectiveAssets(key);
        if (bal0 == 0 && bal1 == 0) return (0, 0);

        uint160 sqrtPriceX96;
        int24 currentTick;
        {
            uint24 protocolFee;
            (sqrtPriceX96, currentTick, protocolFee,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 == 0) return (0, 0);
            feePips = _composeEffectiveFee(feePips, protocolFee, zeroForOne);
        }

        uint128 liquidity = _activeIndicativeLiquidity(poolId, sqrtPriceX96, currentTick, bal0, bal1);
        if (liquidity == 0 || amountSpecified == 0) return (0, 0);

        (, uint256 stepIn, uint256 stepOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceX96, sqrtPriceLimitX96, liquidity, amountSpecified, feePips);
        amountIn = stepIn + feeAmount;
        amountOut = stepOut;
    }

    function _composeEffectiveFee(uint24 lpFee, uint24 protocolFee, bool zeroForOne)
        private
        pure
        returns (uint24)
    {
        uint16 directional = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        return directional == 0 ? lpFee : directional.calculateSwapFee(lpFee);
    }

    function _activeIndicativeLiquidity(PoolId poolId, uint160 sqrtPriceX96, int24 currentTick, uint256 bal0, uint256 bal1)
        internal
        view
        returns (uint128 liquidity)
    {
        LiquidityBucket[] storage dist = _distribution[poolId];
        uint256 n = dist.length;

        for (uint256 i; i < n; i++) {
            if (currentTick < dist[i].tickLower || currentTick >= dist[i].tickUpper) continue;
            // Match `_computeAllocations`: pre-budget each bucket against its weighted share
            // of the balance so the indicative quote tracks what JIT actually deploys.
            uint256 weightBps = dist[i].weightBps;
            uint256 weightedBal0 = bal0 * weightBps / 10_000;
            uint256 weightedBal1 = bal1 * weightBps / 10_000;
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(dist[i].tickLower),
                TickMath.getSqrtPriceAtTick(dist[i].tickUpper),
                weightedBal0,
                weightedBal1
            );
            liquidity += liq;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: AUTH & POOL MANAGER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Revert unless the caller is the owner or external deposits are enabled for the pool.
    /// @param poolId The pool to check authorization for.
    function _requireDepositAuth(PoolId poolId) internal view {
        if (msg.sender == owner()) return;
        if (externalDepositsEnabled[poolId]) return;
        revert Unauthorized();
    }

    /// @dev Verify that the ERC-4626 vault's `asset()` matches the pool's currency. Skipped
    ///      for `address(0)` (no vault — currency held as raw ERC-20). Called only at
    ///      `initializePool` since the vault address is immutable thereafter.
    function _requireVaultMatchesCurrency(IERC4626 vault, Currency currency) internal view {
        if (address(vault) == address(0)) return;
        if (vault.asset() != Currency.unwrap(currency)) revert VaultAssetMismatch();
    }

    /// @dev Provides PoolVault access to the PoolManager for claim operations (burn/take).
    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: ACTIVE LIQUIDITY SLOTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Base transient slot for the active-liquidity array of `poolId`. Per-bucket
    ///      slots are derived as `base + bucketIndex`. Single keccak per JIT cycle, then
    ///      pure addition for each bucket access.
    function _activeLiqBase(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(_ACTIVE_LIQ_NAMESPACE, poolId));
    }
}
