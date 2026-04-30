// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title PoolVault
/// @author Uniswap Labs
///
/// @notice Multi-asset vault for Uniswap v4 pool hooks, inspired by ERC4626.
///
///         Manages proportional share accounting across a pool's two currencies, with per-pool
///         isolation of three asset types:
///
///           1. **ERC4626 vault shares** — assets rehypothecated into yield-bearing vaults between
///              swaps. Tracked per-pool via `_vaultShares` to isolate multi-pool deployments that
///              share the same vault contract.
///
///           2. **ERC-6909 claims** — deferred settlement tokens minted on the PoolManager when
///              afterSwap produces a positive delta but the PM lacks ERC-20 (because the swapper
///              hasn't settled yet). Tracked per-pool via `_claims` and redeemed to ERC-20 in the
///              next beforeSwap.
///
///           3. **Raw ERC-20** — tokens held directly by the hook, attributed per-pool via
///              `_erc20[poolId][currency]`. The mapping is the source of truth for pool ownership;
///              the hook's global `balanceOf` is never read for accounting decisions, ensuring
///              cross-pool isolation when multiple pools share a currency.
///
///         ## Share Model
///
///         Unlike ERC4626, shares are **non-transferable internal accounting**. Each pool has its
///         own share supply tracked via `totalShares` and `userShares` mappings — there is no
///         ERC-20 share token. This avoids the complexity of per-pool token deployment while
///         providing the same proportional claim semantics.
///
///         Share math follows ERC4626 conventions:
///           - Deposits round **up** (depositor pays slightly more, preventing dilution)
///           - Withdrawals round **down** (withdrawer receives slightly less, preventing theft)
///           - First deposit goes through `_bootstrap`, which mints `sqrt(amount0 * amount1)`
///             shares (Uniswap V2 style) and locks `MINIMUM_SHARES` at `address(0)` to prevent
///             share-price inflation attacks. After bootstrap, `totalShares >= MINIMUM_SHARES`
///             permanently — the pool can never be reset.
///           - Conversion uses Solady's `fullMulDiv` / `fullMulDivUp` for overflow-safe precision
///
///         ## Token Compatibility
///
///         Inbound transfers (user → hook) use OZ `SafeERC20.safeTransferFrom` to handle
///         non-standard ERC-20s (USDT). Outbound transfers (hook → user) use v4-core's
///         `Currency.transfer` which is also USDT-safe. Vault approvals use `forceApprove` for
///         tokens that require zero-out-first.
///
///         **Native ETH is NOT supported** — subclasses must reject `address(0)` currencies at
///         pool initialization. PoolVault calls `IERC20.safeTransferFrom(address(0), ...)` which
///         would revert; the subclass-level rejection makes the failure mode explicit at init.
///
///         ## Same-Block Lockup
///
///         To defend against atomic deposit-swap-withdraw fee/yield sniping, `_withdraw` reverts
///         if called in the same block as a prior `_deposit` for the same `(pool, user)`. The
///         attacker would need to wait one block, exposing them to inventory risk and price drift.
///
///         ## Integration
///
///         Subclasses must provide:
///           - `_poolManager()` — access to the v4 PoolManager for claim operations
///           - Authorization logic for deposit/withdraw entry points
///           - A JIT lifecycle (or equivalent) that calls the vault and claim management functions
///             during swap callbacks
///           - Native-ETH rejection at pool initialization (see above)
///
/// @dev    **Storage layout**: per-pool state uses nested mappings keyed by PoolId. The mappings
///         for per-currency data (`vaults`, `_vaultShares`, `_claims`, `_erc20`) are further
///         keyed by Currency. This two-level mapping cannot be packed into a struct, but the
///         scalar per-pool fields (`totalShares`) can be co-located with hook-specific state
///         in subclasses for storage slot packing.
/// @custom:security-contact security@uniswap.org
abstract contract PoolVault is BlockNumberish {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Per-(pool, currency) packed balance state. Co-locates ERC-20 holdings and
    ///      ERC-6909 claim balance in a single 32-byte slot so the pair-aware code paths
    ///      (`_assetBalance`, `_redeemPoolClaims`) read both with one SLOAD instead of two.
    ///      `uint128` per field admits balances up to ~3.4e38, which dwarfs any plausible
    ///      per-pool token amount; deposits/credits SafeCast on write.
    struct CurrencyState {
        uint128 erc20;
        uint128 claims;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Dead shares locked at `address(0)` on first bootstrap. Prevents `totalShares`
    ///         from ever reaching zero again, which would re-enable inflation attacks. Also
    ///         dilutes the very first depositor's share value, making single-wei bootstrap
    ///         attacks unprofitable.
    uint256 public constant MINIMUM_SHARES = 1_000;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice ERC4626 vault for each (pool, currency) pair.
    /// @dev    `address(0)` means no vault is configured — tokens are held as ERC-20 in the hook
    ///         and tracked via `_erc20`. Vaults are typically set at pool initialization and are
    ///         immutable for the pool's lifetime.
    mapping(PoolId => mapping(Currency => IERC4626)) public vaults;

    /// @notice Total shares outstanding for a pool, across all depositors.
    /// @dev    Denominator for proportional share conversions. Always `>= MINIMUM_SHARES`
    ///         after bootstrap; zero only before bootstrap.
    mapping(PoolId => uint256) public totalShares;

    /// @notice Share balance for each (pool, user) pair.
    /// @dev    Numerator for a user's proportional claim on pool assets. `address(0)` holds
    ///         the dead shares from bootstrap.
    mapping(PoolId => mapping(address => uint256)) public userShares;

    /// @dev Number of ERC4626 vault shares this pool owns. Isolated from other pools that may
    ///      use the same vault contract, preventing one pool from consuming another's shares.
    mapping(PoolId => mapping(Currency => uint256)) internal _vaultShares;

    /// @dev Packed per-(pool, currency) ERC-20 + ERC-6909 claim state.
    ///
    ///      `state.erc20`  — ERC-20 tokens held by the hook attributed to this pool. ALWAYS
    ///                       reflects the per-pool share of the hook's global token balance —
    ///                       never substitutes a global `balanceOf` read. Increments on deposit
    ///                       (no-vault path), claim redemption, and vault withdrawal; decrements
    ///                       on withdrawal-to-user, vault deposit, and PM settlement.
    ///      `state.claims` — ERC-6909 claims on the PoolManager attributed to this pool. Claims
    ///                       are minted when afterSwap produces a positive hook delta (the PM
    ///                       may lack ERC-20 since the swapper hasn't settled yet). They are
    ///                       redeemed to ERC-20 in the next beforeSwap via `_redeemPoolClaims`.
    ///                       Per-pool tracking prevents one pool's claim redemption from
    ///                       consuming another pool's claims when the hook serves multiple pools.
    ///
    ///      Co-locating both fields in a single 32-byte slot lets `_assetBalance` and
    ///      `_redeemPoolClaims` read the pair with one SLOAD instead of two.
    mapping(PoolId => mapping(Currency => CurrencyState)) internal _state;

    /// @dev Block number of the last `_deposit` for each (pool, user). `_withdraw` reverts when
    ///      called in the same block, preventing atomic deposit-swap-withdraw fee/yield sniping.
    ///
    ///      Read via `_getBlockNumberish()` (Uniswap's `BlockNumberish`) so the value reflects
    ///      the chain's *fastest* block clock — on Arbitrum One, vanilla `block.number` returns
    ///      the L1 block number (~12s cadence) and many sequencer transactions share the same
    ///      L1 block, defeating the same-block lock. `_getBlockNumberish` returns the Arbitrum
    ///      L2 block number there (and falls back to `block.number` on chains where the two
    ///      coincide).
    mapping(PoolId => mapping(address => uint256)) internal _lastDepositBlock;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted on first deposit (bootstrap) — sets the initial share/asset ratio.
    /// @param poolId   The pool being bootstrapped.
    /// @param provider The address that received the bootstrap shares (less MINIMUM_SHARES).
    /// @param shares   Total shares minted (`sqrt(amount0 * amount1)`).
    /// @param amount0  Currency0 transferred from the bootstraper.
    /// @param amount1  Currency1 transferred from the bootstraper.
    event Bootstrap(PoolId indexed poolId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a depositor mints shares by providing proportional token amounts.
    /// @param poolId   The pool receiving the deposit.
    /// @param provider The address that received the minted shares.
    /// @param shares   The number of shares minted.
    /// @param amount0  The amount of currency0 transferred from the depositor.
    /// @param amount1  The amount of currency1 transferred from the depositor.
    event Deposit(PoolId indexed poolId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a depositor burns shares and receives proportional token amounts.
    /// @param poolId   The pool the withdrawal came from.
    /// @param provider The address whose shares were burned.
    /// @param shares   The number of shares burned.
    /// @param amount0  The amount of currency0 transferred to the withdrawer.
    /// @param amount1  The amount of currency1 transferred to the withdrawer.
    event Withdraw(PoolId indexed poolId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);

    // ═══════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The caller attempted to burn more shares than they hold.
    error InsufficientShares();

    /// @dev `addLiquidity` was called before the pool was bootstrapped via `_bootstrap`.
    error PoolNotBootstrapped();

    /// @dev `_bootstrap` was called for a pool that already has shares.
    error PoolAlreadyBootstrapped();

    /// @dev Bootstrap amounts produce fewer than `MINIMUM_SHARES` shares.
    error InsufficientBootstrap();

    /// @dev `_withdraw` was called in the same block as the depositor's last `_deposit`.
    ///      Prevents atomic deposit-swap-withdraw fee/yield sniping.
    error SameBlockWithdraw();

    /// @dev The vault cannot satisfy the requested withdrawal amount (e.g., paused or capped).
    error VaultLiquidityShortfall();

    /// @dev A vault redemption returned more shares than the pool owns. Defensive check —
    ///      should never trigger if `_vaultShares` accounting is consistent.
    error CrossPoolShareLeak();

    /// @dev `_settleFromPool` was asked to pay more than the pool's tracked ERC-20 balance.
    error InsufficientPoolBalance();

    /// @dev `vault.deposit` returned zero shares for a non-zero asset deposit. Either the vault
    ///      enforces a minimum deposit threshold the pool's amount didn't meet, or the vault is
    ///      misconfigured. Reverting fail-fast prevents asset loss into a vault that gives no
    ///      claim back.
    error ZeroSharesMinted();

    /// @dev `safeTransferFrom` for a deposit/bootstrap delivered fewer tokens than requested
    ///      (typically a fee-on-transfer or rebasing token). The deposit path mints shares
    ///      against the requested amount, so accepting under-receipt would dilute existing LPs.
    ///      Per K-13, FoT/rebasing tokens are not supported as pool currencies — operators
    ///      should configure wrapped (non-rebasing) variants such as wstETH.
    error TransferReceiptShortfall();

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VIEW: ASSET ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the total managed assets for a pool across both currencies.
    /// @dev    Sums vault assets (via `convertToAssets`), ERC-6909 claims, and per-pool ERC-20
    ///         for each currency. Includes yield accrued in vaults.
    /// @param key The pool to query.
    /// @return amount0 Total currency0 assets under management.
    /// @return amount1 Total currency1 assets under management.
    function totalAssets(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1) {
        return _totalAssets(key);
    }

    /// @notice Preview the token amounts required to mint `shares` for a pool.
    /// @dev    Rounds up to prevent existing shareholders from being diluted by new deposits.
    ///         Reverts if the pool is not bootstrapped — call `_bootstrap` first.
    /// @param key    The pool to query.
    /// @param shares The number of shares to preview minting.
    /// @return amount0 Currency0 required (rounded up).
    /// @return amount1 Currency1 required (rounded up).
    function previewDeposit(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertToAmounts(key, shares, true);
    }

    /// @notice Preview the token amounts returned for burning `shares` from a pool.
    /// @dev    Rounds down to prevent over-withdrawal at the expense of remaining shareholders.
    /// @param key    The pool to query.
    /// @param shares The number of shares to preview burning.
    /// @return amount0 Currency0 returned (rounded down).
    /// @return amount1 Currency1 returned (rounded down).
    function previewWithdraw(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertToAmounts(key, shares, false);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: BOOTSTRAP
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Seed the pool with the first deposit. Mints `sqrt(amount0 * amount1)` shares,
    ///      locks `MINIMUM_SHARES` at `address(0)` (preventing future inflation attacks), and
    ///      assigns the remainder to `to`. Caller must be authorized by the subclass — typically
    ///      restricted to the pool owner so the initial share/asset ratio is set correctly for
    ///      mismatched-decimal pairs (e.g., USDC/WETH).
    ///
    ///      Reverts if:
    ///      - `totalShares[poolId] != 0` (already bootstrapped)
    ///      - `amount0 == 0 || amount1 == 0` (cannot price empty pool)
    ///      - `sqrt(amount0 * amount1) <= MINIMUM_SHARES` (bootstrap too small to dilute attacker)
    ///
    /// @param key      The pool to bootstrap.
    /// @param from     The address to pull tokens from.
    /// @param to       The address to credit shares to (less `MINIMUM_SHARES`).
    /// @param amount0  Currency0 to deposit.
    /// @param amount1  Currency1 to deposit.
    /// @return sharesMinted Total shares minted (including the locked MINIMUM_SHARES).
    function _bootstrap(PoolKey calldata key, address from, address to, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 sharesMinted)
    {
        PoolId poolId = key.toId();
        if (totalShares[poolId] != 0) revert PoolAlreadyBootstrapped();
        if (amount0 == 0 || amount1 == 0) revert InsufficientBootstrap();

        // Reconcile actual transferred amount against requested. For standard ERC-20s, received
        // == requested. For fee-on-transfer / rebasing tokens, the contract receives less; share
        // math must use the real receipt to avoid silently inflating share value at the depositor's
        // expense and diluting later LPs.
        uint256 received0 = _safeTransferFromAndMeasure(key.currency0, from, amount0);
        uint256 received1 = _safeTransferFromAndMeasure(key.currency1, from, amount1);
        if (received0 == 0 || received1 == 0) revert InsufficientBootstrap();

        sharesMinted = FixedPointMathLib.sqrt(received0 * received1);
        if (sharesMinted <= MINIMUM_SHARES) revert InsufficientBootstrap();

        _depositToVault(poolId, key.currency0, received0);
        _depositToVault(poolId, key.currency1, received1);

        totalShares[poolId] = sharesMinted;
        userShares[poolId][address(0)] = MINIMUM_SHARES;
        userShares[poolId][to] = sharesMinted - MINIMUM_SHARES;
        _lastDepositBlock[poolId][to] = _getBlockNumberish();

        emit Bootstrap(poolId, to, sharesMinted, received0, received1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Mint `shares` to `to` by pulling proportional token amounts from `from`.
    ///
    ///      Flow: convert shares → transfer tokens → deposit to vaults → update state → emit.
    ///      Amounts are rounded up (depositor pays slightly more) to prevent share dilution.
    ///      Tokens go to the configured ERC4626 vault or are tracked as per-pool ERC-20.
    ///
    ///      Reverts if the pool has not been bootstrapped via `_bootstrap`.
    ///
    /// @param key    The pool to deposit into.
    /// @param from   The address to pull tokens from (must have approved this contract).
    /// @param to     The address to credit shares to.
    /// @param shares The number of shares to mint.
    /// @return amount0 Actual currency0 transferred.
    /// @return amount1 Actual currency1 transferred.
    function _deposit(PoolKey calldata key, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        if (totalShares[poolId] == 0) revert PoolNotBootstrapped();

        (uint256 want0, uint256 want1) = _convertToAmounts(key, shares, true);

        // Effects-first where possible. Share counters are updated before any external call so
        // a reentrant view path (e.g., a callback observing `previewDeposit`) sees a consistent
        // snapshot. Token movements are interactions; the `nonReentrant` guard on the outer
        // entry point prevents reentrant deposits.
        totalShares[poolId] += shares;
        userShares[poolId][to] += shares;
        _lastDepositBlock[poolId][to] = _getBlockNumberish();

        // Pull tokens. Shares are minted against `want{0,1}` (rounded up), so any FoT/rebasing
        // shortfall would dilute existing LPs by leaving the pool short on assets. Fail-fast on
        // under-receipt — operators select non-FoT/non-rebasing currencies per K-13.
        amount0 = want0 > 0 ? _safeTransferFromAndMeasure(key.currency0, from, want0) : 0;
        amount1 = want1 > 0 ? _safeTransferFromAndMeasure(key.currency1, from, want1) : 0;
        if (amount0 < want0 || amount1 < want1) revert TransferReceiptShortfall();

        _depositToVault(poolId, key.currency0, amount0);
        _depositToVault(poolId, key.currency1, amount1);

        emit Deposit(poolId, to, shares, amount0, amount1);
    }

    /// @dev Burn `shares` from `from` and send proportional token amounts to `to`.
    ///
    ///      Flow: validate → convert shares → update state → ensure ERC-20 → transfer → emit.
    ///      Amounts are rounded down (withdrawer receives slightly less) to prevent over-withdrawal.
    ///      Follows checks-effects-interactions: shares are burned before tokens are transferred.
    ///
    ///      Reverts with `SameBlockWithdraw` if `from` deposited in the current block — this
    ///      prevents atomic deposit-swap-withdraw fee/yield sniping (see `_lastDepositBlock`).
    ///
    /// @param key    The pool to withdraw from.
    /// @param from   The address whose shares to burn.
    /// @param to     The address to send tokens to.
    /// @param shares The number of shares to burn.
    /// @return amount0 Actual currency0 transferred.
    /// @return amount1 Actual currency1 transferred.
    function _withdraw(PoolKey calldata key, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        if (_getBlockNumberish() == _lastDepositBlock[poolId][from]) revert SameBlockWithdraw();
        if (userShares[poolId][from] < shares) revert InsufficientShares();

        (amount0, amount1) = _convertToAmounts(key, shares, false);

        totalShares[poolId] -= shares;
        userShares[poolId][from] -= shares;

        _ensureERC20(poolId, key.currency0, amount0);
        _ensureERC20(poolId, key.currency1, amount1);

        if (amount0 > 0) key.currency0.transfer(to, amount0);
        if (amount1 > 0) key.currency1.transfer(to, amount1);

        emit Withdraw(poolId, from, shares, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: SHARE MATH
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Convert a share amount to the equivalent token amounts for both currencies,
    ///      proportional to the pool's current total assets.
    ///
    ///      Reverts if `totalShares == 0` — pre-bootstrap pools have no defined share/asset
    ///      ratio. Subclasses must ensure `_bootstrap` is called before any `_deposit`/`_withdraw`.
    ///
    ///      Uses Solady `fullMulDiv` for overflow-safe 512-bit intermediate precision:
    ///        amount = shares * totalAsset / totalShares
    ///
    /// @param key     The pool to compute amounts for.
    /// @param shares  The number of shares to convert.
    /// @param roundUp True for deposits (round up to prevent dilution),
    ///                false for withdrawals (round down to prevent over-withdrawal).
    /// @return amount0 The equivalent currency0 amount.
    /// @return amount1 The equivalent currency1 amount.
    function _convertToAmounts(PoolKey memory key, uint256 shares, bool roundUp)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        uint256 supply = totalShares[poolId];
        if (supply == 0) revert PoolNotBootstrapped();

        (uint256 total0, uint256 total1) = _totalAssets(key);
        if (roundUp) {
            amount0 = FixedPointMathLib.fullMulDivUp(shares, total0, supply);
            amount1 = FixedPointMathLib.fullMulDivUp(shares, total1, supply);
        } else {
            amount0 = FixedPointMathLib.fullMulDiv(shares, total0, supply);
            amount1 = FixedPointMathLib.fullMulDiv(shares, total1, supply);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: ASSET TRACKING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Total managed assets for a pool across both currencies.
    /// @param key The pool to query.
    /// @return amount0 Total currency0 (vault + claims + ERC-20).
    /// @return amount1 Total currency1 (vault + claims + ERC-20).
    function _totalAssets(PoolKey memory key) internal view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        amount0 = _assetBalance(poolId, key.currency0);
        amount1 = _assetBalance(poolId, key.currency1);
    }

    /// @dev Total managed balance for a single (pool, currency) pair. Sums three sources:
    ///
    ///      1. ERC4626 vault: `vault.convertToAssets(_vaultShares[poolId][currency])`
    ///         Includes accrued yield. Zero if no vault configured.
    ///
    ///      2. ERC-6909 claims: `_claims[poolId][currency]`
    ///         Deferred positive deltas from prior JIT cycles, awaiting redemption.
    ///
    ///      3. Per-pool ERC-20: `_erc20[poolId][currency]`
    ///         Always tracked, regardless of vault config — represents the pool's share of the
    ///         hook's global token balance. Steady-state nonzero only for non-vaulted pools;
    ///         transiently nonzero for vaulted pools mid-JIT-cycle.
    ///
    /// @param poolId   The pool to query.
    /// @param currency The currency to query.
    /// @return bal     The total balance across all three sources.
    function _assetBalance(PoolId poolId, Currency currency) internal view returns (uint256 bal) {
        // Single SLOAD reads both packed fields.
        CurrencyState storage s = _state[poolId][currency];
        bal = uint256(s.erc20) + uint256(s.claims);
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) != address(0)) {
            uint256 shares = _vaultShares[poolId][currency];
            if (shares > 0) bal += vault.convertToAssets(shares);
        }
    }

    /// @dev Liquidity-ready balance for a single (pool, currency) pair. Same composition as
    ///      `_assetBalance`, but caps the vault contribution at `vault.maxWithdraw(this)` so
    ///      callers requesting "what can be deployed right now" see the truth even when the
    ///      vault is paused, capped, or utilization-constrained. Used by routers and aggregators
    ///      to size split fills.
    ///
    ///      Distinction from `_assetBalance` is intentional: share math (`_convertToAmounts`)
    ///      must use the un-capped balance so an LP's pro-rata claim is computed against the
    ///      pool's TRUE economic stake, not the momentarily-withdrawable subset. Capping share
    ///      math would let early withdrawers consume liquidity that later LPs are owed.
    function _effectiveBalance(PoolId poolId, Currency currency) internal view returns (uint256 bal) {
        CurrencyState storage s = _state[poolId][currency];
        bal = uint256(s.erc20) + uint256(s.claims);
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) != address(0)) {
            uint256 shares = _vaultShares[poolId][currency];
            if (shares > 0) {
                uint256 byConvert = vault.convertToAssets(shares);
                uint256 byMaxWithdraw = vault.maxWithdraw(address(this));
                bal += byConvert < byMaxWithdraw ? byConvert : byMaxWithdraw;
            }
        }
    }

    /// @dev Pool-level effective (immediately-withdrawable) assets across both currencies.
    function _effectiveAssets(PoolKey calldata key)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        amount0 = _effectiveBalance(poolId, key.currency0);
        amount1 = _effectiveBalance(poolId, key.currency1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: VAULT OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deposit `amount` of `currency` into the pool's configured ERC4626 vault.
    ///      Caller must have already transferred `amount` tokens to this contract.
    ///      If no vault is configured, the amount is tracked in `_erc20` instead.
    ///      Assumes the vault is already approved (subclasses approve at pool init via
    ///      `_approveVault`). Allowance is set to `type(uint256).max` once and never decremented
    ///      by `vault.deposit`, so the runtime allowance read is unnecessary.
    ///
    ///      ## Vault trust model
    ///
    ///      The hook holds standing max allowance to each (pool, currency) vault. A compromised
    ///      or upgradeable vault for currency X can in principle `transferFrom` the hook's full
    ///      balance of X — including raw ERC-20 attributed to unrelated pools that share that
    ///      currency. This is the documented vault-trust model (K-05): operators MUST select
    ///      vaults whose security properties they understand (immutable / non-upgradeable
    ///      preferred). The exact-per-deposit approval pattern would defuse this surface but
    ///      adds ~15-25k gas to every JIT cycle and every LP entry — rejected as too expensive
    ///      for a risk that is already gated by the maker's vault selection.
    /// @param poolId   The pool this deposit belongs to.
    /// @param currency The currency being deposited.
    /// @param amount   The amount to deposit (0 is a no-op).
    function _depositToVault(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            CurrencyState storage s = _state[poolId][currency];
            s.erc20 = (uint256(s.erc20) + amount).toUint128();
            return;
        }

        // Pre-credit predicted shares so view callers during a vault callback (e.g.,
        // `getReserves`, `previewWithdraw`, `getIndicativeQuote`) observe a coherent
        // total — same mitigation as `_depositAllToVault`. Reconciles after the call.
        uint256 sharesPredicted = vault.convertToShares(amount);
        _vaultShares[poolId][currency] += sharesPredicted;

        uint256 sharesActual = vault.deposit(amount, address(this));

        // Fail-fast on a vault that swallows assets without minting shares — silently
        // accepting `sharesActual == 0` would lose `amount` into the vault.
        if (sharesActual == 0) revert ZeroSharesMinted();

        // Reconcile predicted-vs-actual divergence. Subtraction is safe because the
        // pre-credit just added at least `sharesPredicted`.
        if (sharesActual != sharesPredicted) {
            if (sharesActual > sharesPredicted) {
                _vaultShares[poolId][currency] += (sharesActual - sharesPredicted);
            } else {
                _vaultShares[poolId][currency] -= (sharesPredicted - sharesActual);
            }
        }
    }

    /// @dev Deposit all of the pool's tracked ERC-20 balance for both currencies into vaults.
    ///      Called in afterSwap after the JIT cycle resolves. Uses per-pool `_erc20` rather
    ///      than the hook's global `balanceOf` — critical for cross-pool isolation when the
    ///      hook serves multiple pools sharing a currency.
    /// @param poolId The pool whose assets to re-vault.
    /// @param key    The pool key (for currency references).
    function _depositAllToVaults(PoolId poolId, PoolKey calldata key) internal {
        _depositAllToVault(poolId, key.currency0);
        _depositAllToVault(poolId, key.currency1);
    }

    /// @dev Deposit the pool's tracked ERC-20 balance of a currency into its vault.
    ///      No-op for non-vaulted pools (the balance stays in `_erc20`). Reads only the
    ///      pool's own `_erc20[poolId][currency]`, never the hook's global balance.
    ///      Assumes the vault is already approved (subclasses approve at pool init).
    ///
    ///      ## Read-only reentrancy mitigation
    ///
    ///      A vault callback fired from inside `vault.deposit` would otherwise observe
    ///      `s.erc20 = 0` while the new vault shares haven't been credited yet — view callers
    ///      (aggregators reading `getReserves`, `previewWithdraw`, `getIndicativeQuote`) would
    ///      see this currency's balance temporarily collapse to whatever `convertToAssets` of
    ///      the *old* `_vaultShares` returns. We mitigate by optimistically pre-crediting
    ///      `_vaultShares` with `convertToShares(amount)` before the external call, then
    ///      reconciling against the real share return after. This shrinks the observable
    ///      inconsistency window from the full `amount` to (predicted-vs-actual) drift, which
    ///      is bounded by the vault's deposit-fee policy. A malicious vault that lies on
    ///      `convertToShares` is bounded by what `_assetBalance` reports anyway (it reads
    ///      `convertToAssets` of the same shares) — so the worst case is no worse than today.
    /// @param poolId   The pool this deposit belongs to.
    /// @param currency The currency to deposit.
    function _depositAllToVault(PoolId poolId, Currency currency) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return;
        CurrencyState storage s = _state[poolId][currency];
        uint256 amount = s.erc20;
        if (amount == 0) return;

        // Pre-credit predicted shares so view callers during the callback see a coherent total.
        uint256 sharesPredicted = vault.convertToShares(amount);
        s.erc20 = 0;
        _vaultShares[poolId][currency] += sharesPredicted;

        uint256 sharesActual = vault.deposit(amount, address(this));

        // Fail-fast on a vault that swallows assets without minting shares.
        if (sharesActual == 0) revert ZeroSharesMinted();

        // Reconcile divergence between predicted and actual share return. Most ERC-4626 vaults
        // are exact (sharesActual == sharesPredicted). Fee-skimming or buggy vaults diverge.
        if (sharesActual != sharesPredicted) {
            if (sharesActual > sharesPredicted) {
                _vaultShares[poolId][currency] += (sharesActual - sharesPredicted);
            } else {
                _vaultShares[poolId][currency] -= (sharesPredicted - sharesActual);
            }
        }
    }

    /// @dev Withdraw `amount` of `currency` from the pool's vault, crediting the hook's
    ///      per-pool ERC-20 tracking. Caps at `vault.maxWithdraw` to handle paused or
    ///      utilization-constrained vaults gracefully.
    ///
    ///      Uses ERC4626 `withdraw(assets, ...)` (returns shares burned) rather than
    ///      `redeem(previewWithdraw(assets), ...)` so the asset amount delivered is exact —
    ///      no off-by-one rounding shortfall.
    ///
    /// @param poolId   The pool to withdraw for.
    /// @param currency The currency to withdraw.
    /// @param amount   The target asset amount to withdraw (capped at maxWithdraw).
    function _withdrawFromVault(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return; // already in _state.erc20

        uint256 maxWithdrawable = vault.maxWithdraw(address(this));
        uint256 toWithdraw = amount > maxWithdrawable ? maxWithdrawable : amount;
        if (toWithdraw == 0) return;

        uint256 sharesUsed = vault.withdraw(toWithdraw, address(this), address(this));
        uint256 poolShares = _vaultShares[poolId][currency];
        if (sharesUsed > poolShares) revert CrossPoolShareLeak();
        _vaultShares[poolId][currency] -= sharesUsed;
        CurrencyState storage s = _state[poolId][currency];
        s.erc20 = (uint256(s.erc20) + toWithdraw).toUint128();
    }

    /// @dev Ensure the pool's tracked ERC-20 balance is at least `amount`, then debit it.
    ///
    ///      For vaulted pools: if `_erc20[poolId][currency] < amount`, redeems the shortfall
    ///      from the vault using `vault.withdraw` (exact assets returned, no rounding shortfall).
    ///      Reverts with `VaultLiquidityShortfall` if the vault cannot satisfy the shortfall.
    ///
    ///      For non-vaulted pools: requires `_erc20[poolId][currency] >= amount`. Reverts on
    ///      arithmetic underflow if the pool is undercapitalized.
    ///
    ///      Always debits `_erc20[poolId][currency] -= amount` so the per-pool counter matches
    ///      the actual ERC-20 leaving the contract on the next `transfer`.
    ///
    /// @param poolId   The pool requiring the balance.
    /// @param currency The currency to ensure.
    /// @param amount   The minimum ERC-20 balance needed (also the amount to debit).
    function _ensureERC20(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        CurrencyState storage s = _state[poolId][currency];
        uint256 bal = s.erc20;
        if (bal >= amount) {
            s.erc20 = uint128(bal - amount);
            return;
        }

        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            // Non-vaulted pool with insufficient erc20 — underflow reverts cleanly below.
            s.erc20 = uint128(bal - amount);
            return;
        }

        uint256 shortfall = amount - bal;
        uint256 maxWithdrawable = vault.maxWithdraw(address(this));
        if (shortfall > maxWithdrawable) revert VaultLiquidityShortfall();

        uint256 sharesUsed = vault.withdraw(shortfall, address(this), address(this));
        uint256 poolShares = _vaultShares[poolId][currency];
        if (sharesUsed > poolShares) revert CrossPoolShareLeak();
        _vaultShares[poolId][currency] -= sharesUsed;
        s.erc20 = 0; // bal + shortfall = amount, fully consumed
    }

    /// @dev Transfer `want` of `currency` from `from` to this contract, returning the actual
    ///      amount received (post fee-on-transfer or rebase). Standard ERC-20s satisfy
    ///      `received == want`; for FoT / rebasing tokens the contract sees less. Used by
    ///      `_bootstrap` and `_deposit` so share math reflects real inflow rather than the
    ///      requested-but-not-received amount.
    function _safeTransferFromAndMeasure(Currency currency, address from, uint256 want)
        internal
        returns (uint256 received)
    {
        if (want == 0) return 0;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), want);
        uint256 balAfter = token.balanceOf(address(this));
        // Defensive: balAfter >= balBefore for any non-malicious transfer; underflow reverts cleanly.
        received = balAfter - balBefore;
    }

    /// @dev Set max approval for a vault using OZ `forceApprove` (zeros out first for
    ///      USDT-style tokens). Skipped if the allowance is already nonzero — `vault.deposit`
    ///      with `type(uint256).max` allowance never decrements, so a single approval suffices
    ///      for the lifetime of the (currency, vault) pair.
    ///
    ///      Subclasses MUST call this once per (currency, vault) pair at pool initialization,
    ///      before any vault deposit can occur. Hot-path deposit functions skip the runtime
    ///      allowance check on the assumption that init-time approval is in place — saves a
    ///      ~2.7K-gas SLOAD on the token contract on every JIT cycle.
    ///
    ///      The standing allowance is the documented vault-trust trade-off: a compromised vault
    ///      for currency X can withdraw up to the hook's full X balance, including amounts
    ///      attributed to other pools sharing that currency. Operators MUST select vaults whose
    ///      security properties they understand (immutable / non-upgradeable preferred). See K-05.
    function _approveVault(Currency currency, address vault) internal {
        if (vault == address(0)) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), vault) == 0) {
            token.forceApprove(vault, type(uint256).max);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: CLAIM MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Redeem this pool's ERC-6909 claims to ERC-20 via the PoolManager.
    ///
    ///      Claims are burned on the PM and the equivalent ERC-20 is taken to this contract.
    ///      Only callable within a v4 unlock context (i.e., during swap callbacks) because
    ///      `burn` and `take` require an active lock.
    ///
    ///      Increments `_erc20[poolId][currency]` by the redeemed amount so the per-pool
    ///      tracking matches the contract's actual balance increase. Returns the post-redeem
    ///      `_erc20` balance so callers don't need a follow-up SLOAD.
    ///
    /// @param poolId   The pool whose claims to redeem.
    /// @param currency The currency to redeem claims for.
    /// @return erc20Bal Post-redeem `_erc20[poolId][currency]` balance.
    function _redeemPoolClaims(PoolId poolId, Currency currency) internal returns (uint256 erc20Bal) {
        // Single SLOAD reads both packed fields.
        CurrencyState memory snapshot = _state[poolId][currency];
        uint256 claimBal = snapshot.claims;
        erc20Bal = snapshot.erc20;
        if (claimBal > 0) {
            _poolManager().burn(address(this), currency.toId(), claimBal);
            _poolManager().take(currency, address(this), claimBal);
            erc20Bal += claimBal;
            // Single SSTORE clears claims while incrementing erc20.
            _state[poolId][currency] = CurrencyState({erc20: erc20Bal.toUint128(), claims: 0});
        }
    }

    /// @dev Record newly minted ERC-6909 claims for a pool. Called after `poolManager.mint()`
    ///      in the JIT delta resolution, when the hook has a positive delta that cannot be
    ///      settled as ERC-20 (the swapper hasn't paid yet).
    /// @param poolId   The pool the claims belong to.
    /// @param currency The currency of the claims.
    /// @param amount   The claim amount to record.
    function _recordClaims(PoolId poolId, Currency currency, uint256 amount) internal {
        CurrencyState storage s = _state[poolId][currency];
        s.claims = (uint256(s.claims) + amount).toUint128();
    }

    /// @dev Debit `amount` from the pool's tracked ERC-20 balance after a PM settlement.
    ///      Called by subclasses' `_resolveNetDelta` paths — the hook just paid `amount` to
    ///      the PM via `_settle`, so the per-pool counter must match the actual outflow.
    ///
    ///      Reverts if the pool's tracked ERC-20 is insufficient, indicating an upstream
    ///      accounting bug. The actual `_settle` call (which physically transfers to PM) is
    ///      the subclass's responsibility — this function only updates the per-pool counter.
    ///
    /// @param poolId   The pool whose balance to debit.
    /// @param currency The currency that was paid.
    /// @param amount   The amount paid.
    function _debitPoolERC20(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        CurrencyState storage s = _state[poolId][currency];
        uint256 bal = s.erc20;
        if (bal < amount) revert InsufficientPoolBalance();
        s.erc20 = uint128(bal - amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ABSTRACT: POOL MANAGER ACCESS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Subclasses must provide access to the v4 PoolManager. Required for claim
    ///      operations (`burn`, `take`) in `_redeemPoolClaims`. Typically returns
    ///      `poolManager` from the BaseHook inheritance chain.
    function _poolManager() internal view virtual returns (IPoolManager);
}
