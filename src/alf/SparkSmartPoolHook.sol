// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
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
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SpreadQuoterBase} from "./base/SpreadQuoterBase.sol";
import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";
import {ALFHookData} from "./interfaces/IALFHook.sol";

/// @title SparkSmartPoolHook
/// @author ALF
/// @notice Rehypothecating spread quoter using Just-In-Time (JIT) liquidity for Spark's stablecoin
///         markets. All pool assets live in ERC4626 vaults earning yield between swaps. Liquidity is
///         deployed to the pool only for the duration of each swap:
///
///           beforeSwap  → withdraw from vaults, deploy concentrated LP
///           [pool executes swap against the LP]
///           afterSwap   → remove LP, re-deposit to vaults
///
///         Pricing is via SpreadQuoterBase fee overrides with EIP-712 signed curve updates. Each pool
///         supports a configurable tick range, per-currency ERC4626 vault assignment, and optional
///         external deposits with share-based accounting.
///
/// @dev    Key invariants:
///         - Between swaps, the pool holds zero liquidity. All assets are in vaults or as ERC-20/claims.
///         - During a swap, the hook's delta from deploy+remove nets to a small value (fees ± IL).
///         - Positive net deltas are minted as ERC-6909 claims (PoolManager may lack ERC-20 since
///           the swapper settles after afterSwap). Claims are redeemed in the next beforeSwap.
///         - Total managed assets = ERC-20 balance + ERC-6909 claims + ERC4626 vault balance.
contract SparkSmartPoolHook is SpreadQuoterBase, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // ──── Constants ────

    /// @notice Salt used for the hook's LP positions in the PoolManager.
    bytes32 public constant LP_SALT = bytes32(uint256(0x5350524B)); // "SPRK"

    /// @dev Rounding direction for share-to-amount conversions.
    enum Rounding {
        Floor,
        Ceil
    }

    // ──── Per-Pool Vault Config ────

    /// @notice ERC4626 vault for each (pool, currency). `address(0)` means no vault —
    ///         tokens are held as ERC-20 in the hook with no rehypothecation.
    mapping(PoolId => mapping(Currency => IERC4626)) public vaults;

    // ──── Per-Pool Tick Range ────

    /// @notice Lower tick bound for JIT liquidity deployment.
    mapping(PoolId => int24) public poolTickLower;

    /// @notice Upper tick bound for JIT liquidity deployment.
    mapping(PoolId => int24) public poolTickUpper;

    // ──── Per-Pool Share Accounting ────

    /// @notice Total outstanding shares for a pool, across all depositors.
    mapping(PoolId => uint256) public totalShares;

    /// @notice Shares held by each address for a given pool.
    mapping(PoolId => mapping(address => uint256)) public userShares;

    // ──── Per-Pool Config ────

    /// @notice Whether non-operator addresses may call `addLiquidity` for this pool.
    mapping(PoolId => bool) public externalDepositsEnabled;

    /// @notice Per-pool operator address, authorized for deposits, withdrawals, and LP operations.
    mapping(PoolId => address) public poolOperator;

    // ──── JIT State ────

    /// @dev Liquidity deployed by `_deployJIT` in beforeSwap, removed in afterSwap. Zero between swaps.
    mapping(PoolId => uint128) internal _activeJITLiquidity;

    // ──── Pool Keys ────

    /// @dev Stored for multi-pool support; each pool's key is recorded at initialization.
    mapping(PoolId => PoolKey) internal _poolKeys;

    // ──── Events ────

    /// @notice Emitted when a new pool is initialized via `initializePool`.
    event PoolCreated(PoolId indexed poolId, int24 tickLower, int24 tickUpper, address operator);

    /// @notice Emitted when an ERC4626 vault is configured (or removed) for a (pool, currency) pair.
    event VaultConfigured(PoolId indexed poolId, Currency indexed currency, address vault);

    /// @notice Emitted when a depositor adds liquidity and receives shares.
    event LiquidityAdded(
        PoolId indexed poolId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when a depositor burns shares and withdraws tokens.
    event LiquidityRemoved(
        PoolId indexed poolId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when the JIT tick range is updated for a pool.
    event TickRangeUpdated(PoolId indexed poolId, int24 tickLower, int24 tickUpper);

    // ──── Errors ────

    /// @dev Thrown when an address other than the hook itself tries to add/remove pool liquidity.
    error LiquidityNotAllowed();

    /// @dev Thrown when a non-authorized address attempts to deposit into a pool that has
    ///      external deposits disabled.
    error ExternalDepositsDisabled();

    /// @dev Thrown when a user tries to burn more shares than they hold.
    error InsufficientShares();

    /// @dev Thrown when `initializePool` is called with a hook address that doesn't match this contract.
    error InvalidHookAddress();

    /// @dev Thrown when `initializePool` is called with a non-dynamic fee.
    error MustUseDynamicFee();

    /// @dev Thrown when an unauthorized caller attempts a restricted operation.
    error Unauthorized();

    // ──── Constructor ────

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param _attestationRegistry The attestation registry for flow-based fee discounts.
    /// @param maxGas_      Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_       Initial contract owner (Ownable2Step).
    constructor(
        IPoolManager _poolManager,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_,
        address owner_
    ) SpreadQuoterBase(_poolManager, _attestationRegistry, maxGas_, owner_, "SparkSmartPoolHook") {}

    // ──── Hook Permissions ────

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
    //                         POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool with this hook and configure all parameters in one call.
    /// @dev    Calls `poolManager.initialize` internally. Because v4 skips hook callbacks when
    ///         `msg.sender == key.hooks`, `_afterInitialize` won't fire — the ALF index
    ///         registration is performed inline instead.
    /// @param key                  The PoolKey (must reference this hook and use DYNAMIC_FEE_FLAG).
    /// @param sqrtPriceX96         Initial sqrt price (Q64.96). Use `TickMath.getSqrtPriceAtTick(0)`
    ///                             for a 1:1 stablecoin pair.
    /// @param pricing              Initial bid/ask spread configuration.
    /// @param tickLower            Lower tick of the JIT liquidity range (must be aligned to tickSpacing).
    /// @param tickUpper            Upper tick of the JIT liquidity range (must be aligned to tickSpacing).
    /// @param operator             Address authorized for day-to-day operations (deposit, withdraw, etc.).
    /// @param allowExternalDeposits Whether non-operator addresses may call `addLiquidity`.
    /// @return tick                The initial tick assigned by the PoolManager.
    function initializePool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        PricingState calldata pricing,
        int24 tickLower,
        int24 tickUpper,
        address operator,
        bool allowExternalDeposits
    ) external onlyOwner returns (int24 tick) {
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert MustUseDynamicFee();
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower % key.tickSpacing != 0 || tickUpper % key.tickSpacing != 0) revert InvalidTickRange();

        PoolId poolId = key.toId();
        _poolKeys[poolId] = key;
        pricingState[poolId] = pricing;
        poolTickLower[poolId] = tickLower;
        poolTickUpper[poolId] = tickUpper;
        poolOperator[poolId] = operator;
        externalDepositsEnabled[poolId] = allowExternalDeposits;

        tick = poolManager.initialize(key, sqrtPriceX96);

        emit PoolCreated(poolId, tickLower, tickUpper, operator);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Blocks direct pool initialization — callers must use `initializePool`.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert Unauthorized();
    }

    /// @dev Only the hook itself may add liquidity (during JIT deployment in beforeSwap).
    ///      All external LP attempts via PositionManager or direct modifyLiquidity are rejected.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Only the hook itself may remove liquidity (during JIT teardown in afterSwap).
    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != address(this)) revert LiquidityNotAllowed();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev JIT entry point. Resolves pricing (curve update, attestation, fee override) then deploys
    ///      all managed assets as concentrated LP at the configured tick range.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // 1. Pricing: curve updates, attestation, fee override
        uint24 feeOverride = _resolvePricing(poolId, key, params.zeroForOne, hookData);
        if (feeOverride == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 2. Deploy JIT liquidity from vaults
        _deployJIT(poolId, key);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    /// @dev JIT teardown. Removes the LP deployed in beforeSwap, resolves the net delta, and
    ///      re-deposits ERC-20 to vaults.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        uint128 liquidity = _activeJITLiquidity[poolId];

        if (liquidity > 0) {
            // Remove JIT liquidity — creates positive delta that partially offsets the deploy debt.
            // Net delta = fee revenue +/- IL (small amounts relative to total position).
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: poolTickLower[poolId],
                    tickUpper: poolTickUpper[poolId],
                    liquidityDelta: -int256(uint256(liquidity)),
                    salt: LP_SALT
                }),
                ""
            );

            _activeJITLiquidity[poolId] = 0;

            // Resolve net delta. Uses mint (ERC-6909 claims) for positive deltas because
            // the PoolManager may not hold enough ERC-20 (swapper hasn't settled yet).
            _resolveNetDelta(key.currency0);
            _resolveNetDelta(key.currency1);

            // Re-deposit remaining ERC-20 to vaults. Any positive net delta that was minted
            // as claims will be redeemed to ERC-20 in the next beforeSwap.
            _depositAllToVaults(poolId, key);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          JIT INTERNALS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Resolve pricing from hookData. Applies any signed curve update, checks attestation,
    ///      and computes the fee override. Returns 0 if the pool is not live (swap should no-op).
    function _resolvePricing(PoolId poolId, PoolKey calldata, bool zeroForOne, bytes calldata hookData)
        internal
        returns (uint24 feeOverride)
    {
        bool isAttested;
        if (hookData.length > 0) {
            ALFHookData memory hd = abi.decode(hookData, (ALFHookData));
            if (hd.curveUpdateData.length > 0) {
                _applyCurveUpdate(poolId, hd.curveUpdateData);
            }
            if (hd.attestationData.length > 0) {
                (isAttested,) = _resolveAttestation(hd.attestationData);
            }
        }

        PricingState memory state = pricingState[poolId];
        if (!state.live) return 0;

        uint24 feePips = _effectiveFee(state, zeroForOne, isAttested);
        return feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    /// @dev Deploy all managed assets as JIT liquidity. Withdraws from ERC4626 vaults, redeems
    ///      any accumulated ERC-6909 claims, then adds concentrated LP at the configured tick range.
    ///
    ///      The deploy creates a negative delta for the hook (it owes tokens to the pool). This debt
    ///      is intentionally NOT settled here — it nets out in afterSwap when the LP is removed.
    ///      Settling here would fail for the "incoming" token because the PoolManager doesn't hold
    ///      the swapper's payment yet (swapper settles after afterSwap completes).
    function _deployJIT(PoolId poolId, PoolKey calldata key) internal {
        (uint256 bal0, uint256 bal1) = _getTotalAssets(poolId, key);
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 tl = poolTickLower[poolId];
        int24 tu = poolTickUpper[poolId];

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), bal0, bal1
        );
        if (liquidity == 0) return;

        // Withdraw from vaults to get ERC-20 (needed for settling negative net delta in afterSwap)
        _withdrawAllFromVaults(poolId, key);

        // Redeem any accumulated ERC-6909 claims from previous swaps to ERC-20
        _redeemClaimsIfAny(key.currency0);
        _redeemClaimsIfAny(key.currency1);

        // Deploy LP — creates negative delta for hook (owes tokens to pool).
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(liquidity)), salt: LP_SALT}),
            ""
        );

        _activeJITLiquidity[poolId] = liquidity;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                         DELTA RESOLUTION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Burn any ERC-6909 claims held by the hook and take the equivalent ERC-20 from the
    ///      PoolManager. Claims accumulate when afterSwap mints positive deltas (because the PM
    ///      may lack ERC-20 at that point). This is called in beforeSwap where the PM has been
    ///      funded by prior settlements.
    function _redeemClaimsIfAny(Currency currency) internal {
        uint256 claims = poolManager.balanceOf(address(this), currency.toId());
        if (claims > 0) {
            poolManager.burn(address(this), currency.toId(), claims);
            poolManager.take(currency, address(this), claims);
        }
    }

    /// @dev Resolve the hook's net delta for a single currency after the JIT deploy+remove cycle.
    ///      - Negative delta (hook owes pool): settle from ERC-20 on hand.
    ///      - Positive delta (pool owes hook): mint as ERC-6909 claims. The PoolManager may not
    ///        hold enough ERC-20 for a `take` because the swapper settles after afterSwap returns.
    ///        Claims are redeemed to ERC-20 in the next `_deployJIT` call.
    function _resolveNetDelta(Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            _settle(currency, address(this), uint256(-delta));
        } else if (delta > 0) {
            poolManager.mint(address(this), currency.toId(), uint256(delta));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                         VAULT OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deposit `amount` of `currency` into the configured ERC4626 vault for `poolId`.
    ///      No-ops if amount is zero or no vault is configured.
    function _depositToVault(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return;
        IERC20Minimal(Currency.unwrap(currency)).approve(address(vault), amount);
        vault.deposit(amount, address(this));
    }

    /// @dev Withdraw `amount` of `currency` from the configured ERC4626 vault for `poolId`.
    ///      No-ops if amount is zero or no vault is configured.
    function _withdrawFromVault(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return;
        vault.withdraw(amount, address(this), address(this));
    }

    /// @dev Withdraw all vault shares for both pool currencies, converting to ERC-20.
    function _withdrawAllFromVaults(PoolId poolId, PoolKey calldata key) internal {
        _withdrawAllFromVault(poolId, key.currency0);
        _withdrawAllFromVault(poolId, key.currency1);
    }

    /// @dev Redeem all vault shares for a single currency, converting to ERC-20.
    function _withdrawAllFromVault(PoolId poolId, Currency currency) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return;
        uint256 shares = vault.balanceOf(address(this));
        if (shares > 0) {
            vault.redeem(shares, address(this), address(this));
        }
    }

    /// @dev Deposit all ERC-20 balances for both pool currencies into their vaults.
    function _depositAllToVaults(PoolId poolId, PoolKey calldata key) internal {
        _depositAllToVault(poolId, key.currency0);
        _depositAllToVault(poolId, key.currency1);
    }

    /// @dev Deposit the hook's entire ERC-20 balance of a currency into its vault.
    function _depositAllToVault(PoolId poolId, Currency currency) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return;
        uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal > 0) {
            IERC20Minimal(Currency.unwrap(currency)).approve(address(vault), bal);
            vault.deposit(bal, address(this));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                         ASSET TRACKING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Returns total managed assets for both currencies: ERC-20 + ERC-6909 claims + vault.
    function _getTotalAssets(PoolId poolId, PoolKey memory key)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = _getAssetBalance(poolId, key.currency0);
        amount1 = _getAssetBalance(poolId, key.currency1);
    }

    /// @dev Returns total managed balance for a single (pool, currency) pair:
    ///      ERC-20 held by the hook + ERC-6909 claims on the PoolManager + ERC4626 vault balance.
    function _getAssetBalance(PoolId poolId, Currency currency) internal view returns (uint256) {
        address underlying = Currency.unwrap(currency);
        uint256 bal = IERC20Minimal(underlying).balanceOf(address(this));
        // Include ERC-6909 claims (accumulated from JIT positive deltas)
        bal += poolManager.balanceOf(address(this), currency.toId());
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) != address(0)) {
            uint256 vaultShares = vault.balanceOf(address(this));
            if (vaultShares > 0) {
                bal += vault.convertToAssets(vaultShares);
            }
        }
        return bal;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INDICATIVE QUOTES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Indicative quote using hypothetical JIT liquidity.
    /// @dev    Overrides SpreadQuoterBase which calls SwapSimulator against pool state — but since
    ///         JIT means zero onchain liquidity between swaps, the base implementation returns 0.
    ///         This override computes the JIT liquidity from vault assets and simulates a single
    ///         swap step with `SwapMath.computeSwapStep`.
    /// @param key              The pool to quote for.
    /// @param zeroForOne       Swap direction.
    /// @param amountSpecified  Swap amount (negative = exact input).
    /// @param hookData         Optional hookData containing attestation for fee discounts.
    /// @return outputAmount    Estimated output amount.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        bool isAttested;
        if (hookData.length > 0) {
            ALFHookData memory hd = abi.decode(hookData, (ALFHookData));
            if (hd.attestationData.length > 0) {
                (, bool valid) = attestationRegistry.verify(hd.attestationData);
                isAttested = valid;
            }
        }
        return _price(key, zeroForOne, amountSpecified, isAttested, address(0));
    }

    /// @dev Compute indicative output using hypothetical JIT liquidity and a single SwapMath step.
    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool isAttested, address)
        internal
        view
        override
        returns (uint256 outputAmount)
    {
        PoolId poolId = key.toId();
        PricingState memory state = pricingState[poolId];
        if (!state.live) return 0;

        uint128 liquidity = _computeJITLiquidity(poolId, key);
        if (liquidity == 0) return 0;

        uint24 feePips = _effectiveFee(state, zeroForOne, isAttested);
        return _simulateSwapStep(poolId, zeroForOne, amountSpecified, liquidity, feePips);
    }

    /// @dev Compute the JIT liquidity that would be deployed given current vault + ERC-20 assets
    ///      and the pool's current price.
    function _computeJITLiquidity(PoolId poolId, PoolKey memory key) internal view returns (uint128) {
        (uint256 bal0, uint256 bal1) = _getTotalAssets(poolId, key);
        if (bal0 == 0 && bal1 == 0) return 0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(poolTickLower[poolId]),
            TickMath.getSqrtPriceAtTick(poolTickUpper[poolId]),
            bal0,
            bal1
        );
    }

    /// @dev Single-step swap simulation against hypothetical JIT liquidity.
    ///      Accurate for swaps that don't exhaust the entire concentrated position.
    function _simulateSwapStep(PoolId poolId, bool zeroForOne, int256 amountSpecified, uint128 liquidity, uint24 feePips)
        internal
        view
        returns (uint256 amountOut)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 limit = zeroForOne
            ? TickMath.getSqrtPriceAtTick(poolTickLower[poolId])
            : TickMath.getSqrtPriceAtTick(poolTickUpper[poolId]);
        (,, amountOut,) = SwapMath.computeSwapStep(sqrtPriceX96, limit, liquidity, amountSpecified, feePips);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       RESERVES / TVL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns total reserves managed by this hook for the given pool.
    /// @dev Includes ERC-20, ERC-6909 claims, and ERC4626 vault balances.
    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _getTotalAssets(key.toId(), key);
    }

    /// @notice Returns assets available for immediate swapping.
    /// @dev For JIT with instant-withdrawal ERC4626 vaults, effective liquidity equals reserves.
    ///      Would differ if a vault had withdrawal delays or caps.
    function getEffectiveLiquidity(PoolKey calldata key)
        external
        view
        override
        returns (uint256 token0, uint256 token1)
    {
        return _getTotalAssets(key.toId(), key);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       LP DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit token0 and token1 proportional to the pool's current asset ratio, receive shares.
    /// @dev    For the first deposit (totalShares == 0), shares mint 1:1 with each token amount.
    ///         Amounts are rounded up (Ceil) to prevent share dilution. Deposited tokens are
    ///         immediately routed to the configured ERC4626 vaults.
    /// @param key           The pool to deposit into.
    /// @param sharesToMint  Number of shares to mint. Use `previewAddLiquidity` to see required amounts.
    /// @return amount0      Actual amount of token0 transferred from the caller.
    /// @return amount1      Actual amount of token1 transferred from the caller.
    function addLiquidity(PoolKey calldata key, uint256 sharesToMint)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        _requireDepositAuth(poolId);

        (amount0, amount1) = _convertSharesToAmounts(key, sharesToMint, Rounding.Ceil);

        // Transfer tokens from depositor
        if (amount0 > 0) {
            IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1);
        }

        // Deposit to vaults
        _depositToVault(poolId, key.currency0, amount0);
        _depositToVault(poolId, key.currency1, amount1);

        // Mint shares
        totalShares[poolId] += sharesToMint;
        userShares[poolId][msg.sender] += sharesToMint;

        emit LiquidityAdded(poolId, msg.sender, sharesToMint, amount0, amount1);
    }

    /// @notice Burn shares and receive proportional token0 + token1.
    /// @dev    Amounts are rounded down (Floor) to prevent over-withdrawal. Tokens are withdrawn
    ///         from vaults if the hook's ERC-20 balance is insufficient.
    /// @param key           The pool to withdraw from.
    /// @param sharesToBurn  Number of shares to burn. Use `previewRemoveLiquidity` to see return amounts.
    /// @return amount0      Actual amount of token0 transferred to the caller.
    /// @return amount1      Actual amount of token1 transferred to the caller.
    function removeLiquidity(PoolKey calldata key, uint256 sharesToBurn)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        if (userShares[poolId][msg.sender] < sharesToBurn) revert InsufficientShares();

        (amount0, amount1) = _convertSharesToAmounts(key, sharesToBurn, Rounding.Floor);

        // Burn shares first (checks-effects-interactions)
        totalShares[poolId] -= sharesToBurn;
        userShares[poolId][msg.sender] -= sharesToBurn;

        // Withdraw from vaults if ERC-20 balance is insufficient
        _ensureBalance(poolId, key.currency0, amount0);
        _ensureBalance(poolId, key.currency1, amount1);

        // Transfer tokens to withdrawer
        if (amount0 > 0) {
            IERC20Minimal(Currency.unwrap(key.currency0)).transfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20Minimal(Currency.unwrap(key.currency1)).transfer(msg.sender, amount1);
        }

        emit LiquidityRemoved(poolId, msg.sender, sharesToBurn, amount0, amount1);
    }

    // ──── Internal: Share Math ────

    /// @dev Convert a share amount to the equivalent token0 and token1 amounts based on the
    ///      pool's current total assets and total shares. For the first deposit (totalShares == 0),
    ///      1 share = 1 unit of each token.
    function _convertSharesToAmounts(PoolKey memory key, uint256 shares, Rounding rounding)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        uint256 _totalShares = totalShares[poolId];
        if (_totalShares == 0) return (shares, shares);

        (uint256 total0, uint256 total1) = _getTotalAssets(poolId, key);

        if (rounding == Rounding.Ceil) {
            amount0 = Math.ceilDiv(shares * total0, _totalShares);
            amount1 = Math.ceilDiv(shares * total1, _totalShares);
        } else {
            amount0 = shares * total0 / _totalShares;
            amount1 = shares * total1 / _totalShares;
        }
    }

    /// @dev Ensure the hook holds at least `amount` of ERC-20 for `currency`. If not, withdraw
    ///      the shortfall from the configured vault.
    function _ensureBalance(PoolId poolId, Currency currency, uint256 amount) internal {
        uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal >= amount) return;
        _withdrawFromVault(poolId, currency, amount - bal);
    }

    /// @dev Revert if the caller is not authorized to deposit into the pool.
    ///      Owner and poolOperator are always authorized. External users require
    ///      `externalDepositsEnabled[poolId]` to be true.
    function _requireDepositAuth(PoolId poolId) internal view {
        if (msg.sender == owner() || msg.sender == poolOperator[poolId]) return;
        if (externalDepositsEnabled[poolId]) return;
        revert ExternalDepositsDisabled();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       OWNER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configure or remove an ERC4626 vault for a (pool, currency) pair.
    /// @dev    If changing from one vault to another and the old vault holds shares, they are
    ///         redeemed first. If `vault` is `address(0)`, rehypothecation is disabled for this
    ///         asset and tokens are held as ERC-20 in the hook.
    /// @param key      The pool to configure.
    /// @param currency The currency to assign a vault to.
    /// @param vault    The ERC4626 vault, or `IERC4626(address(0))` to disable.
    function setVault(PoolKey calldata key, Currency currency, IERC4626 vault) external onlyOwner {
        PoolId poolId = key.toId();

        // If changing vaults and old vault holds funds, withdraw first
        IERC4626 oldVault = vaults[poolId][currency];
        if (address(oldVault) != address(0) && address(oldVault) != address(vault)) {
            uint256 oldShares = oldVault.balanceOf(address(this));
            if (oldShares > 0) {
                oldVault.redeem(oldShares, address(this), address(this));
            }
        }

        vaults[poolId][currency] = vault;

        // If new vault is set and we hold ERC-20, deposit it
        if (address(vault) != address(0)) {
            uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
            if (bal > 0) {
                IERC20Minimal(Currency.unwrap(currency)).approve(address(vault), bal);
                vault.deposit(bal, address(this));
            }
        }

        emit VaultConfigured(poolId, currency, address(vault));
    }

    /// @notice Update the tick range used for JIT liquidity deployment.
    /// @dev    Both ticks must be aligned to the pool's tick spacing.
    /// @param key       The pool to update.
    /// @param tickLower New lower tick bound.
    /// @param tickUpper New upper tick bound.
    function setTickRange(PoolKey calldata key, int24 tickLower, int24 tickUpper) external onlyOwner {
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower % key.tickSpacing != 0 || tickUpper % key.tickSpacing != 0) revert InvalidTickRange();

        PoolId poolId = key.toId();
        poolTickLower[poolId] = tickLower;
        poolTickUpper[poolId] = tickUpper;

        emit TickRangeUpdated(poolId, tickLower, tickUpper);
    }

    /// @notice Set or change the operator address for a pool.
    /// @param key      The pool to update.
    /// @param operator The new operator address.
    function setPoolOperator(PoolKey calldata key, address operator) external onlyOwner {
        poolOperator[key.toId()] = operator;
    }

    /// @notice Enable or disable external (non-operator) deposits for a pool.
    /// @param key     The pool to update.
    /// @param enabled `true` to allow any address to call `addLiquidity`.
    function setExternalDeposits(PoolKey calldata key, bool enabled) external onlyOwner {
        externalDepositsEnabled[key.toId()] = enabled;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the share balance of `user` in the given pool.
    /// @param key  The pool to query.
    /// @param user The address to check.
    /// @return     The number of shares held.
    function sharesOf(PoolKey calldata key, address user) external view returns (uint256) {
        return userShares[key.toId()][user];
    }

    /// @notice Preview the token amounts that would be returned for burning `shares`.
    /// @dev    Amounts are rounded down (Floor). Actual withdrawal may differ if vault yields
    ///         accrue between the preview call and the withdrawal.
    /// @param key    The pool to query.
    /// @param shares The number of shares to preview burning.
    /// @return amount0 Estimated token0 returned.
    /// @return amount1 Estimated token1 returned.
    function previewRemoveLiquidity(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertSharesToAmounts(key, shares, Rounding.Floor);
    }

    /// @notice Preview the token amounts required for minting `shares`.
    /// @dev    Amounts are rounded up (Ceil). Caller should approve at least these amounts.
    /// @param key    The pool to query.
    /// @param shares The number of shares to preview minting.
    /// @return amount0 Estimated token0 required.
    /// @return amount1 Estimated token1 required.
    function previewAddLiquidity(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertSharesToAmounts(key, shares, Rounding.Ceil);
    }
}
