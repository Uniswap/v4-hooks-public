// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapSimulator} from "./libraries/SwapSimulator.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SpreadQuoterBase} from "./base/SpreadQuoterBase.sol";
import {PoolVault} from "./base/PoolVault.sol";

/// @title SmartPoolHook
/// @notice JIT spread quoter with ERC4626 vault rehypothecation and multi-range liquidity
///         distribution.
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
///         Bid/ask spreads are set via SpreadQuoterBase's PricingState and applied as a v4
///         dynamic fee override. The owner updates spreads through `updatePricingState`. This
///         hook intentionally **ignores hookData on swaps** — pricing is fully owner-controlled.
///         The signed-curve-update infrastructure inherited from `SpreadQuoterBase` is therefore
///         dormant for SmartPoolHook pools.
///
///         ## Share Accounting
///
///         Inherited from PoolVault. Pools are seeded by the owner via `bootstrap`, which mints
///         `sqrt(amount0 * amount1)` shares (Uniswap V2 style) and locks `MINIMUM_SHARES` at
///         `address(0)` to prevent share-price inflation attacks. After bootstrap, anyone with
///         deposit auth may call `addLiquidity` for proportional shares. LPs hold proportional
///         shares of the pool's total assets (vault shares + claims + per-pool ERC-20).
///
///         ## Reentrancy
///
///         User-facing entry points (`bootstrap`, `addLiquidity`, `removeLiquidity`) carry the
///         OZ `nonReentrant` transient guard. PM-driven callbacks (`_beforeSwap`, `_afterSwap`)
///         are not eligible for that guard (no fresh entry point), so they manage a separate
///         `JIT_LOCK` transient slot and the LP entries reject calls while it is set. This
///         blocks an owner-configured ERC4626 vault from re-entering LP entry points mid-JIT.
contract SmartPoolHook is SpreadQuoterBase, PoolVault, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;
    using SafeERC20 for IERC20;

    /// @notice Salt for the hook's LP positions in the PoolManager, distinguishing them
    ///         from positions created by other hooks or LPs on the same pool.
    bytes32 public constant LP_SALT = bytes32(uint256(0x534D5254)); // "SMRT"

    /// @notice Maximum number of buckets per pool. Bounds gas cost of the JIT cycle:
    ///         each bucket requires one modifyLiquidity call to deploy and one to remove,
    ///         so gas scales linearly with bucket count.
    uint8 public constant MAX_BUCKETS = 8;

    /// @dev Transient namespace for per-pool JIT locks. The slot for `poolId` is
    ///      `keccak256(abi.encode(_JIT_LOCK_NAMESPACE, poolId))`. Per-pool scoping is required
    ///      so a cross-pool reentry (vault on pool A invokes a swap on pool B during pool A's
    ///      JIT cycle) cannot clear pool A's lock when pool B's `_afterSwap` runs. Independent
    ///      from OZ's `ReentrancyGuardTransient` slot, which only covers user-initiated entry.
    bytes32 private constant _JIT_LOCK_NAMESPACE = keccak256("smartpoolhook.jit.lock.v2");

    /// @dev Transient slot for the global "any JIT in flight" counter. Incremented on
    ///      `_setJITLock`, decremented on `_clearJITLock`. Read by `whenJITNotInProgress`
    ///      to reject ANY reentrant user/admin call that originates inside an in-flight JIT
    ///      cycle anywhere in this hook — closing the cross-pool path that a per-pool lock
    ///      alone would leave open (e.g., `addLiquidity(A)` invoked while pool B is mid-cycle
    ///      via a shared malicious vault).
    bytes32 private constant _JIT_GLOBAL_COUNTER_SLOT = keccak256("smartpoolhook.jit.global.v1");

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
    /// @param pricing              Initial bid/ask spread configuration. Fees must be ≤ MAX_LP_FEE.
    /// @param distribution         Liquidity distribution buckets (weights must sum to 10_000).
    /// @param allowExternalDeposits Whether non-owner addresses may call `addLiquidity`.
    /// @param vault0               ERC4626 vault for currency0 (address(0) to hold as ERC-20).
    /// @param vault1               ERC4626 vault for currency1 (address(0) to hold as ERC-20).
    struct PoolConfig {
        uint160 sqrtPriceX96;
        PricingState pricing;
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

    /// @dev Stored pool keys for multi-pool support.
    mapping(PoolId => PoolKey) internal _poolKeys;

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

    /// @dev The PoolKey's fee must use DYNAMIC_FEE_FLAG for fee override pricing.
    error MustUseDynamicFee();

    /// @dev Caller is not authorized (not owner, or external deposits disabled).
    error Unauthorized();

    /// @dev Distribution is invalid: empty, exceeds MAX_BUCKETS, weights don't sum to 10_000,
    ///      or a bucket has zero weight.
    error InvalidDistribution();

    /// @dev Pool initialization rejected because one of the currencies is native ETH
    ///      (`address(0)`). PoolVault uses `IERC20.safeTransferFrom` which cannot operate on
    ///      `address(0)`, and the hook lacks a `receive() payable` function. Operators must
    ///      use a wrapped-ETH variant (e.g., WETH9) instead.
    error NativeNotSupported();

    /// @dev A user-facing or admin entry point was called from inside an active JIT cycle.
    ///      Triggered when an owner-configured ERC4626 vault attempts to re-enter the hook
    ///      via `vault.deposit` / `vault.withdraw` callbacks during `_beforeSwap` / `_afterSwap`.
    error JITInProgress();

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _pm     The Uniswap v4 PoolManager.
    /// @param maxGas_ Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_  Initial contract owner (Ownable2Step).
    constructor(
        IPoolManager _pm,
        uint32 maxGas_,
        address owner_
    ) SpreadQuoterBase(_pm, maxGas_, owner_, "SmartPoolHook") {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Reverts if ANY pool's JIT cycle is currently in flight (M-01). Reads the global
    ///      counter rather than a per-pool slot so cross-pool reentry is rejected: a vault
    ///      callback during pool A's cycle cannot enter `addLiquidity(B)` (or `bootstrap(B)`,
    ///      `setDistribution(B)`, etc.) even though pool B is not itself locked. Audit fix
    ///      for C-01 / S-01.
    modifier whenJITNotInProgress() {
        if (_isAnyJITInProgress()) revert JITInProgress();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool with vaults, pricing, and liquidity distribution.
    /// @dev    Calls `poolManager.initialize` internally. Vaults are permanent — set at creation
    ///         and cannot be changed. The distribution can be updated later via `setDistribution`.
    ///         Native ETH (currency `address(0)`) is rejected — wrap as WETH instead.
    ///         Pricing fees must be ≤ `LPFeeLibrary.MAX_LP_FEE`.
    ///         The pool is **not seeded** by `initializePool`; the owner must call `bootstrap`
    ///         to mint the first shares before any swaps or external deposits can occur.
    /// @param key    The PoolKey (must reference this hook and use DYNAMIC_FEE_FLAG).
    /// @param config Pool configuration including pricing, distribution, vaults, and permissions.
    /// @return tick  The initial tick assigned by the PoolManager.
    function initializePool(PoolKey calldata key, PoolConfig calldata config)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert MustUseDynamicFee();
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeNotSupported();
        // Fail-fast on bad pricing before any state writes or the (gas-heavy) PM initialize call.
        _validateFeeBounds(config.pricing);

        PoolId poolId = key.toId();
        _poolKeys[poolId] = key;
        externalDepositsEnabled[poolId] = config.allowExternalDeposits;
        vaults[poolId][key.currency0] = config.vault0;
        vaults[poolId][key.currency1] = config.vault1;

        // Approve once at init time so JIT-cycle vault deposits can skip the runtime
        // allowance read. Allowance set to `type(uint256).max` is never decremented by
        // `vault.deposit`, so a single approval is durable for the (currency, vault) pair.
        _approveVault(key.currency0, address(config.vault0));
        _approveVault(key.currency1, address(config.vault1));

        _setDistribution(poolId, config.distribution, key.tickSpacing);

        tick = poolManager.initialize(key, config.sqrtPriceX96);
        // Commit pricing AFTER PM initialize: `updateDynamicLPFee` requires `checkPoolInitialized`.
        _commitPricingState(key, config.pricing);
        emit PoolCreated(poolId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: LP DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Seed a pool with the first deposit. Mints `sqrt(amount0 * amount1)` shares,
    ///         locks `MINIMUM_SHARES` at `address(0)`, and credits the owner with the rest.
    /// @dev    Only the owner may bootstrap. The owner-supplied amounts set the initial
    ///         share/asset ratio, which is critical for asymmetric-decimal pairs (e.g.,
    ///         USDC/WETH) where a naïve 1-wei-of-each bootstrap would either be unaffordable
    ///         or set a meaningless price. Reverts if the pool is already bootstrapped or if
    ///         `sqrt(amount0 * amount1) <= MINIMUM_SHARES`.
    /// @param key     The pool to bootstrap.
    /// @param amount0 Currency0 to deposit.
    /// @param amount1 Currency1 to deposit.
    /// @return shares Total shares minted (including the locked dead shares).
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
    ///         block to defend against atomic deposit-swap-withdraw fee/yield sniping (H-03).
    /// @param key          The pool to deposit into.
    /// @param sharesToMint Number of shares to mint. Use `previewDeposit` to see required amounts.
    /// @return amount0     Actual currency0 transferred from the caller.
    /// @return amount1     Actual currency1 transferred from the caller.
    function addLiquidity(PoolKey calldata key, uint256 sharesToMint)
        external
        nonReentrant
        whenJITNotInProgress
        returns (uint256 amount0, uint256 amount1)
    {
        _requireDepositAuth(key.toId());
        return _deposit(key, msg.sender, msg.sender, sharesToMint);
    }

    /// @notice Burn shares and receive proportional token0 + token1.
    /// @dev    Amounts are rounded down to prevent over-withdrawal. Tokens are withdrawn
    ///         from vaults via `vault.withdraw` (exact assets) if the pool's tracked ERC-20
    ///         is insufficient. Reverts in the same block as the depositor's last deposit
    ///         (anti-fee-sniping, H-03).
    /// @param key          The pool to withdraw from.
    /// @param sharesToBurn Number of shares to burn. Use `previewWithdraw` to see return amounts.
    /// @return amount0     Actual currency0 transferred to the caller.
    /// @return amount1     Actual currency1 transferred to the caller.
    function removeLiquidity(PoolKey calldata key, uint256 sharesToBurn)
        external
        nonReentrant
        whenJITNotInProgress
        returns (uint256 amount0, uint256 amount1)
    {
        return _withdraw(key, msg.sender, msg.sender, sharesToBurn);
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
    /// @dev    Recovery path for vaults whose `deposit` decrements `type(uint256).max`
    ///         allowance (non-spec but observable on certain proxy upgrades), or for tokens
    ///         that zero allowances on governance events. Without this, a one-time
    ///         `forceApprove` at `initializePool` would silently brick the pool. Audit fix
    ///         for F-04 / M-03.
    ///
    ///         Zero-out-then-max via `forceApprove` to remain USDT-safe.
    /// @param key      The pool to refresh approval for.
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
    /// @dev    Reverts during an active JIT cycle (any pool) — gated for defence-in-depth so a
    ///         vault-as-owner callback cannot flip deposit auth mid-cycle to combine with later
    ///         reentry. Audit fix for H-02.
    /// @param key     The pool to update.
    /// @param enabled True to allow any address to call `addLiquidity`.
    function setExternalDeposits(PoolKey calldata key, bool enabled)
        external
        onlyOwner
        whenJITNotInProgress
    {
        externalDepositsEnabled[key.toId()] = enabled;
    }

    /// @notice Disabled — SmartPoolHook deploys multi-bucket distributions, not single-tick LP.
    /// @dev    `activeLowerTick` is inherited from `SpreadQuoterBase` for the single-tick LP
    ///         model used by other subclasses. SmartPoolHook ignores it entirely, so allowing
    ///         the owner to "set" it would be a footgun (no behavioral effect, but visible state
    ///         change). Always reverts.
    function setActiveTick(PoolKey calldata, int24) external view override onlyOwner {
        revert Unauthorized();
    }

    /// @inheritdoc SpreadQuoterBase
    /// @dev    Overridden to gate on `whenJITNotInProgress` (audit fix for H-02). A vault-as-owner
    ///         callback inside an in-flight JIT cycle cannot mutate pricing state mid-flight.
    function updatePricingState(PoolKey calldata key, PricingState calldata state)
        external
        override
        onlyOwner
        whenJITNotInProgress
    {
        _commitPricingState(key, state);
    }

    /// @inheritdoc SpreadQuoterBase
    /// @dev    Overridden to gate on `whenJITNotInProgress` (audit fix for H-02).
    function setPoolLive(PoolKey calldata key, bool live)
        external
        override
        onlyOwner
        whenJITNotInProgress
    {
        PricingState memory state = pricingState[key.toId()];
        state.live = live;
        _commitPricingState(key, state);
        emit PoolLivenessUpdated(key.toId(), live);
    }

    /// @inheritdoc SpreadQuoterBase
    /// @dev    Overridden to gate on `whenJITNotInProgress` (audit fix for H-02). Dormant on
    ///         SmartPoolHook today (hookData ignored) but guarded for defence-in-depth so a
    ///         future subclass that re-enables hookData paths inherits the protection.
    function setPriceSigner(address _priceSigner) external override onlyOwner whenJITNotInProgress {
        priceSigner = _priceSigner;
        emit PriceSignerUpdated(_priceSigner);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: IALFHook OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Indicative quote against hypothetical multi-range JIT liquidity.
    /// @dev    Aggregates liquidity across all distribution buckets and runs a virtual
    ///         tick-walk simulation. **Ignores hookData entirely** — pricing is fully
    ///         determined by the stored `pricingState` set via owner / `updatePricingState`.
    ///         This intentionally diverges from the parent `SpreadQuoterBase`, which would
    ///         apply unsigned hookData pricing to the quote.
    /// @param key              The pool to quote for.
    /// @param zeroForOne       Swap direction (true = token0 → token1).
    /// @param amountSpecified  Swap amount (negative = exact input, positive = exact output).
    /// @return outputAmount    For exact input: estimated output. For exact output: required input.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        return _price(key, zeroForOne, amountSpecified, false, address(0));
    }

    /// @notice Simulate a price-bounded swap against hypothetical JIT liquidity.
    /// @dev    Same hookData-ignoring policy as `getIndicativeQuote`.
    /// @param key                The pool to simulate.
    /// @param zeroForOne         Swap direction.
    /// @param amountSpecified    Swap amount (negative = exact input).
    /// @param sqrtPriceLimitX96  Target price (Q64.96). Swap stops when reached.
    /// @return amountIn          Total input consumed (including fees).
    /// @return amountOut         Total output received.
    function swapToPrice(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        view
        override
        returns (uint256 amountIn, uint256 amountOut)
    {
        return _swapToPrice(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    /// @notice Total reserves managed by this hook for the given pool.
    /// @dev    Includes ERC-20, ERC-6909 claims, and ERC4626 vault balances.
    /// @param key    The pool to query.
    /// @return token0 Total currency0 under management.
    /// @return token1 Total currency1 under management.
    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _totalAssets(key);
    }

    /// @notice Assets available for immediate swapping.
    /// @dev    For JIT hooks, effective liquidity equals reserves since all assets are
    ///         deployable. Would differ for vaults with withdrawal delays or caps.
    /// @param key    The pool to query.
    /// @return token0 Immediately deployable currency0.
    /// @return token1 Immediately deployable currency1.
    function getEffectiveLiquidity(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _totalAssets(key);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the share balance of `user` for the given pool.
    /// @param key  The pool to query.
    /// @param user The address to check.
    /// @return     The number of shares held by `user`.
    function sharesOf(PoolKey calldata key, address user) external view returns (uint256) {
        return userShares[key.toId()][user];
    }

    /// @notice Returns the current liquidity distribution for a pool.
    /// @param poolId The pool to query.
    /// @return       Array of liquidity buckets with their tick ranges and weights.
    function getDistribution(PoolId poolId) external view returns (LiquidityBucket[] memory) {
        return _distribution[poolId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        PUBLIC: HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Required v4 hook flags:
    ///      - beforeInitialize: block direct init (force initializePool)
    ///      - afterInitialize: inherited from SpreadQuoterBase (active tick setup)
    ///      - beforeAddLiquidity / beforeRemoveLiquidity: restrict to hook-only LP
    ///      - beforeSwap: JIT deployment + fee override
    ///      - afterSwap: JIT teardown + delta resolution
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
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

    /// @dev Blocks direct pool initialization. Callers must use `initializePool` which
    ///      validates parameters and configures the distribution before calling PM.initialize.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert Unauthorized();
    }

    /// @dev Only the hook itself may add pool liquidity (during JIT deployment in _beforeSwap).
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal view override returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Only the hook itself may remove pool liquidity (during JIT teardown in _afterSwap).
    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal view override returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev JIT entry point. Reads the stored PricingState for the directional fee, deploys
    ///      multi-range JIT liquidity under the JIT lock, and returns the fee override. Returns
    ///      zero delta and no fee if the pool is not live (swap executes against zero liquidity →
    ///      no output). hookData is ignored entirely (see contract-level NatSpec).
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PricingState memory state = pricingState[poolId];
        if (!state.live) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint24 feePips = params.zeroForOne ? state.bidFeePips : state.askFeePips;
        _setJITLock(poolId);
        _deployJIT(poolId, key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev JIT teardown. Removes all bucket positions, resolves the hook's net delta for both
    ///      currencies (debiting per-pool ERC-20 on settle), re-deposits remaining ERC-20 to
    ///      vaults, and clears the JIT lock.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal override returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        // If beforeSwap returned early (pool not live), JIT lock was never set — skip teardown.
        // Note: this checks the per-pool lock, NOT the global counter. A different pool's JIT
        // cycle being in flight does not affect whether this pool's own teardown should run.
        if (!_isJITLocked(poolId)) {
            return (IHooks.afterSwap.selector, 0);
        }
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
    ///           hook serves multiple pools sharing a currency (C-01).
    ///        3. **Deploy**: add each bucket as a concentrated LP position.
    ///
    /// @param poolId The pool to deploy for.
    /// @param key    The pool key (for currency references and modifyLiquidity calls).
    function _deployJIT(PoolId poolId, PoolKey calldata key) internal {
        (uint256 bal0, uint256 bal1) = _totalAssets(key);
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

            uint128 maxLiq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtLower, sqrtUpper, bal0, bal1
            );
            uint128 liq = uint128(uint256(maxLiq) * dist[i].weightBps / 10_000);
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
    ///      pool's share of the hook's actual token balance (C-01 invariant).
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

    /// @dev Indicative output using hypothetical multi-range JIT liquidity. Builds a virtual
    ///      tick schedule from the distribution and simulates a full multi-step tick walk.
    /// @param key              The pool to simulate.
    /// @param zeroForOne       Swap direction.
    /// @param amountSpecified  Swap amount (negative = exact input).
    /// @return outputAmount    Estimated output for exact-in, or required input for exact-out.
    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool, address)
        internal view override returns (uint256 outputAmount)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (, outputAmount) = _simulateVirtual(key, zeroForOne, amountSpecified, limit);
    }

    /// @dev Price-bounded swap simulation using virtual tick walk.
    /// @param key                The pool to simulate.
    /// @param zeroForOne         Swap direction.
    /// @param amountSpecified    Swap amount (negative = exact input).
    /// @param sqrtPriceLimitX96  Target price limit (Q64.96).
    /// @return amountIn          Total input consumed (including fees).
    /// @return amountOut         Total output received.
    function _swapToPrice(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal view returns (uint256 amountIn, uint256 amountOut)
    {
        return _simulateVirtual(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    /// @dev Build the virtual tick schedule from the distribution buckets and run a full
    ///      multi-step swap simulation via SwapSimulator.simulateSwapVirtual.
    ///
    ///      The tick schedule is constructed by computing each bucket's weighted liquidity
    ///      (same allocation as _deployJIT) and emitting +liquidityDelta at tickLower and
    ///      -liquidityDelta at tickUpper. The schedule is then sorted and passed to the
    ///      virtual simulator, which walks ticks exactly as Pool.sol would.
    ///
    /// @param key                The pool to simulate.
    /// @param zeroForOne         Swap direction.
    /// @param amountSpecified    Swap amount (negative = exact input).
    /// @param sqrtPriceLimitX96  Price limit for the simulation.
    /// @return amountIn          Total input consumed.
    /// @return amountOut         Total output received.
    function _simulateVirtual(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal view returns (uint256 amountIn, uint256 amountOut)
    {
        PoolId poolId = key.toId();

        uint24 feePips;
        {
            PricingState memory state = pricingState[poolId];
            if (!state.live) return (0, 0);
            feePips = zeroForOne ? state.bidFeePips : state.askFeePips;
        }

        return _runVirtualSim(poolId, key, zeroForOne, amountSpecified, feePips, sqrtPriceLimitX96);
    }

    /// @dev Extracted to manage stack depth. Builds tick schedule and calls simulateSwapVirtual.
    ///      Combines the LP fee with the pool's directional protocol fee (if any) so the quote
    ///      matches `Pool.swap`'s effective swap fee. Audit fix for EC-01.
    function _runVirtualSim(
        PoolId poolId, PoolKey calldata key, bool zeroForOne,
        int256 amountSpecified, uint24 feePips, uint160 sqrtPriceLimitX96
    ) private view returns (uint256 amountIn, uint256 amountOut) {
        (uint256 bal0, uint256 bal1) = _totalAssets(key);
        if (bal0 == 0 && bal1 == 0) return (0, 0);

        uint160 sqrtPriceX96;
        int24 currentTick;
        // Inner block: read slot0 and combine fees here so the protocolFee local does not
        // contribute to outer stack pressure during _buildTickSchedule.
        {
            uint24 protocolFee;
            (sqrtPriceX96, currentTick, protocolFee,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 == 0) return (0, 0);
            feePips = _composeEffectiveFee(feePips, protocolFee, zeroForOne);
        }

        (SwapSimulator.TickDelta[] memory sorted, uint128 liqAtTick) =
            _buildTickSchedule(poolId, sqrtPriceX96, currentTick, bal0, bal1);
        if (sorted.length == 0) return (0, 0);

        return SwapSimulator.simulateSwapVirtual(
            sqrtPriceX96, currentTick, liqAtTick,
            zeroForOne, amountSpecified, feePips, sqrtPriceLimitX96, sorted
        );
    }

    /// @dev Mirror `Pool.swap`'s fee composition: combine LP fee with the directional protocol
    ///      fee. Without this combination, quotes over-state output whenever governance enables
    ///      a protocol fee on the pool.
    function _composeEffectiveFee(uint24 lpFee, uint24 protocolFee, bool zeroForOne)
        private
        pure
        returns (uint24)
    {
        uint16 directional = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        return directional == 0 ? lpFee : directional.calculateSwapFee(lpFee);
    }

    /// @dev Build a sorted, merged tick schedule from the distribution for virtual simulation.
    /// @param poolId      The pool to build for.
    /// @param sqrtPriceX96 Current pool sqrt price.
    /// @param currentTick  Current pool tick.
    /// @param bal0         Available currency0.
    /// @param bal1         Available currency1.
    /// @return sorted                  Sorted, merged tick deltas.
    /// @return liquidityAtCurrentTick  Sum of liquidity from buckets active at currentTick.
    function _buildTickSchedule(PoolId poolId, uint160 sqrtPriceX96, int24 currentTick, uint256 bal0, uint256 bal1)
        internal view returns (SwapSimulator.TickDelta[] memory sorted, uint128 liquidityAtCurrentTick)
    {
        LiquidityBucket[] storage dist = _distribution[poolId];
        uint256 n = dist.length;
        if (n == 0) return (sorted, 0);

        SwapSimulator.TickDelta[] memory ticks = new SwapSimulator.TickDelta[](n * 2);
        uint256 count;

        for (uint256 i; i < n; i++) {
            uint128 maxLiq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(dist[i].tickLower),
                TickMath.getSqrtPriceAtTick(dist[i].tickUpper),
                bal0, bal1
            );
            uint128 liq = uint128(uint256(maxLiq) * dist[i].weightBps / 10_000);
            if (liq == 0) continue;

            // SafeCast: revert if `liq > type(int128).max` (~1.7e38). The naive `int128(liq)`
            // cast would silently wrap to negative for `liq >= 2^127`, corrupting the virtual
            // sim while the real JIT deploy path (`_deployBuckets`, casts via int256) stays
            // correct — producing quote/execution divergence. Audit fix for EC-02.
            int128 liqSigned = uint256(liq).toInt128();
            ticks[count++] = SwapSimulator.TickDelta({tick: dist[i].tickLower, liquidityNet: liqSigned});
            ticks[count++] = SwapSimulator.TickDelta({tick: dist[i].tickUpper, liquidityNet: -liqSigned});

            if (currentTick >= dist[i].tickLower && currentTick < dist[i].tickUpper) {
                liquidityAtCurrentTick += liq;
            }
        }

        if (count == 0) return (sorted, 0);
        sorted = _sortAndMergeTicks(ticks, count);
    }

    /// @dev Sort tick deltas ascending and merge entries at the same tick.
    /// @dev Sort tick deltas ascending by tick, merge same-tick entries, return trimmed array.
    ///      Insertion sort in Solidity (correct, auditable), assembly only for the final copy.
    /// @param ticks Raw tick deltas (modified in place during sort/merge).
    /// @param count Number of valid entries.
    /// @return result Sorted, merged array trimmed to final size.
    function _sortAndMergeTicks(SwapSimulator.TickDelta[] memory ticks, uint256 count)
        internal pure returns (SwapSimulator.TickDelta[] memory result)
    {
        // Phase 1: insertion sort in-place (bounded by 2 * MAX_BUCKETS = 16).
        for (uint256 i = 1; i < count; ++i) {
            SwapSimulator.TickDelta memory tmp = ticks[i];
            uint256 j = i;
            while (j > 0 && ticks[j - 1].tick > tmp.tick) {
                ticks[j] = ticks[j - 1];
                --j;
            }
            ticks[j] = tmp;
        }

        // Phase 2: in-place merge — write pointer stays <= read pointer.
        uint256 w;
        for (uint256 r; r < count; ++r) {
            if (w > 0 && ticks[w - 1].tick == ticks[r].tick) {
                ticks[w - 1].liquidityNet += ticks[r].liquidityNet;
            } else {
                if (r != w) ticks[w] = ticks[r];
                ++w;
            }
        }

        // Phase 3: allocate trimmed result.
        result = new SwapSimulator.TickDelta[](w);
        for (uint256 i; i < w; ++i) {
            result[i] = ticks[i];
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

    /// @dev Provides PoolVault access to the PoolManager for claim operations (burn/take).
    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: JIT LOCK
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Set the per-pool JIT lock and increment the global in-flight counter. Called at
    ///      the top of `_beforeSwap` when the pool is live. The per-pool slot scopes teardown
    ///      detection in `_afterSwap`; the global counter scopes the user/admin entry-point
    ///      guard so cross-pool reentry is rejected.
    function _setJITLock(PoolId poolId) private {
        bytes32 perPool = _jitLockSlot(poolId);
        bytes32 global = _JIT_GLOBAL_COUNTER_SLOT;
        assembly ("memory-safe") {
            tstore(perPool, 1)
            tstore(global, add(tload(global), 1))
        }
    }

    /// @dev Clear the per-pool JIT lock and decrement the global counter. Called at the end of
    ///      `_afterSwap`. Idempotent only when paired correctly with `_setJITLock` — callers
    ///      must check `_isJITLocked(poolId)` before invoking, otherwise the counter underflows.
    function _clearJITLock(PoolId poolId) private {
        bytes32 perPool = _jitLockSlot(poolId);
        bytes32 global = _JIT_GLOBAL_COUNTER_SLOT;
        assembly ("memory-safe") {
            tstore(perPool, 0)
            tstore(global, sub(tload(global), 1))
        }
    }

    /// @dev Returns whether the given pool has its own JIT cycle in flight.
    function _isJITLocked(PoolId poolId) private view returns (bool locked) {
        bytes32 slot = _jitLockSlot(poolId);
        assembly ("memory-safe") {
            locked := tload(slot)
        }
    }

    /// @dev Returns whether ANY pool served by this hook has a JIT cycle in flight. Used by
    ///      `whenJITNotInProgress` to reject cross-pool reentry from a vault callback (audit
    ///      finding C-01 / S-01).
    function _isAnyJITInProgress() private view returns (bool inProgress) {
        bytes32 slot = _JIT_GLOBAL_COUNTER_SLOT;
        assembly ("memory-safe") {
            inProgress := iszero(iszero(tload(slot)))
        }
    }

    /// @dev Per-pool transient slot for the JIT lock.
    function _jitLockSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(_JIT_LOCK_NAMESPACE, poolId));
    }

    /// @dev Base transient slot for the active-liquidity array of `poolId`. Per-bucket
    ///      slots are derived as `base + bucketIndex`. Single keccak per JIT cycle, then
    ///      pure addition for each bucket access.
    function _activeLiqBase(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(_ACTIVE_LIQ_NAMESPACE, poolId));
    }
}
