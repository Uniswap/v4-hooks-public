// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
///           3. **Raw ERC-20** — tokens held directly by the hook for pools without a configured
///              vault. Tracked per-pool via `_erc20` since the hook's global ERC-20 balance is
///              not attributable to any single pool.
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
///           - First deposit: 1 share = 1 unit of each token (no virtual shares)
///           - Conversion uses Solady's `fullMulDiv` / `fullMulDivUp` for overflow-safe precision
///
///         ## Integration
///
///         Subclasses must provide:
///           - `_poolManager()` — access to the v4 PoolManager for claim operations
///           - Authorization logic for deposit/withdraw entry points
///           - A JIT lifecycle (or equivalent) that calls the vault and claim management functions
///             during swap callbacks
///
/// @dev    **Storage layout**: per-pool state uses nested mappings keyed by PoolId. The mappings
///         for per-currency data (`vaults`, `_vaultShares`, `_claims`, `_erc20`) are further
///         keyed by Currency. This two-level mapping cannot be packed into a struct, but the
///         scalar per-pool fields (`totalShares`) can be co-located with hook-specific state
///         in subclasses for storage slot packing.
abstract contract PoolVault {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice ERC4626 vault for each (pool, currency) pair.
    /// @dev    `address(0)` means no vault is configured — tokens are held as ERC-20 in the hook
    ///         and tracked via `_erc20`. Vaults are typically set at pool initialization and are
    ///         immutable for the pool's lifetime.
    mapping(PoolId => mapping(Currency => IERC4626)) public vaults;

    /// @notice Total shares outstanding for a pool, across all depositors.
    /// @dev    Denominator for proportional share conversions. Zero when no deposits have been made.
    mapping(PoolId => uint256) public totalShares;

    /// @notice Share balance for each (pool, user) pair.
    /// @dev    Numerator for a user's proportional claim on pool assets.
    mapping(PoolId => mapping(address => uint256)) public userShares;

    /// @dev Number of ERC4626 vault shares this pool owns. Isolated from other pools that may
    ///      use the same vault contract, preventing one pool from consuming another's shares.
    mapping(PoolId => mapping(Currency => uint256)) internal _vaultShares;

    /// @dev ERC-6909 claims on the PoolManager attributed to this pool. Claims are minted when
    ///      afterSwap produces a positive hook delta (the PM may lack ERC-20 since the swapper
    ///      hasn't settled yet). They are redeemed to ERC-20 in the next beforeSwap via
    ///      `_redeemPoolClaims`. Per-pool tracking prevents one pool's claim redemption from
    ///      consuming another pool's claims when the hook serves multiple pools.
    mapping(PoolId => mapping(Currency => uint256)) internal _claims;

    /// @dev ERC-20 tokens held by the hook on behalf of this pool. Only used for pools where
    ///      no ERC4626 vault is configured — the raw balance is not attributable to any pool
    ///      without explicit tracking.
    mapping(PoolId => mapping(Currency => uint256)) internal _erc20;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VIEW: ASSET ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the total managed assets for a pool across both currencies.
    /// @dev    Sums vault assets (via `convertToAssets`), ERC-6909 claims, and raw ERC-20
    ///         for each currency. Includes yield accrued in vaults.
    /// @param key The pool to query.
    /// @return amount0 Total currency0 assets under management.
    /// @return amount1 Total currency1 assets under management.
    function totalAssets(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1) {
        return _totalAssets(key);
    }

    /// @notice Preview the token amounts required to mint `shares` for a pool.
    /// @dev    Rounds up to prevent existing shareholders from being diluted by new deposits.
    ///         Callers should approve at least these amounts before calling deposit.
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
    //                          INTERNAL: DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Mint `shares` to `to` by pulling proportional token amounts from `from`.
    ///
    ///      Flow: convert shares → transfer tokens → deposit to vaults → update state → emit.
    ///      Amounts are rounded up (depositor pays slightly more) to prevent share dilution.
    ///      Tokens go to the configured ERC4626 vault or are tracked as per-pool ERC-20.
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
        (amount0, amount1) = _convertToAmounts(key, shares, true);
        PoolId poolId = key.toId();

        if (amount0 > 0) IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(from, address(this), amount0);
        if (amount1 > 0) IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(from, address(this), amount1);

        _depositToVault(poolId, key.currency0, amount0);
        _depositToVault(poolId, key.currency1, amount1);

        totalShares[poolId] += shares;
        userShares[poolId][to] += shares;

        emit Deposit(poolId, to, shares, amount0, amount1);
    }

    /// @dev Burn `shares` from `from` and send proportional token amounts to `to`.
    ///
    ///      Flow: validate → convert shares → update state → ensure ERC-20 → transfer → emit.
    ///      Amounts are rounded down (withdrawer receives slightly less) to prevent over-withdrawal.
    ///      Follows checks-effects-interactions: shares are burned before tokens are transferred.
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
        if (userShares[poolId][from] < shares) revert InsufficientShares();

        (amount0, amount1) = _convertToAmounts(key, shares, false);

        totalShares[poolId] -= shares;
        userShares[poolId][from] -= shares;

        _ensureERC20(poolId, key.currency0, amount0);
        _ensureERC20(poolId, key.currency1, amount1);

        if (amount0 > 0) IERC20Minimal(Currency.unwrap(key.currency0)).transfer(to, amount0);
        if (amount1 > 0) IERC20Minimal(Currency.unwrap(key.currency1)).transfer(to, amount1);

        emit Withdraw(poolId, from, shares, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: SHARE MATH
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Convert a share amount to the equivalent token amounts for both currencies,
    ///      proportional to the pool's current total assets.
    ///
    ///      When `totalShares == 0` (first deposit), returns `(shares, shares)` — 1 share buys
    ///      1 unit of each token. This bootstraps the share price without requiring an oracle.
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
        if (supply == 0) return (shares, shares);

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
    ///      3. Raw ERC-20: `_erc20[poolId][currency]`
    ///         Only nonzero for pools without a vault.
    ///
    /// @param poolId   The pool to query.
    /// @param currency The currency to query.
    /// @return bal     The total balance across all three sources.
    function _assetBalance(PoolId poolId, Currency currency) internal view returns (uint256 bal) {
        bal = _claims[poolId][currency] + _erc20[poolId][currency];
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) != address(0)) {
            uint256 shares = _vaultShares[poolId][currency];
            if (shares > 0) bal += vault.convertToAssets(shares);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: VAULT OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deposit `amount` of `currency` into the pool's configured ERC4626 vault.
    ///      If no vault is configured, the amount is tracked in `_erc20` instead.
    ///      Vault shares received are recorded in `_vaultShares` for per-pool isolation.
    /// @param poolId   The pool this deposit belongs to.
    /// @param currency The currency being deposited.
    /// @param amount   The amount to deposit (0 is a no-op).
    function _depositToVault(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _erc20[poolId][currency] += amount;
            return;
        }
        _ensureVaultApproval(currency, address(vault));
        uint256 shares = vault.deposit(amount, address(this));
        _vaultShares[poolId][currency] += shares;
    }

    /// @dev Withdraw all redeemable vault shares for both currencies of a pool.
    ///      Caps each redemption at `vault.maxRedeem(address(this))` to handle vaults
    ///      with high utilization that cannot honor full withdrawal.
    /// @param poolId The pool whose vaults to drain.
    /// @param key    The pool key (for currency references).
    function _withdrawAllFromVaults(PoolId poolId, PoolKey calldata key) internal {
        _withdrawAllFromVault(poolId, key.currency0);
        _withdrawAllFromVault(poolId, key.currency1);
    }

    /// @dev Withdraw all redeemable shares for a single (pool, currency) from its vault.
    ///      Redeems `min(poolShares, vault.maxRedeem(this))` to gracefully handle vaults
    ///      that cap withdrawals due to utilization, timelocks, or other constraints.
    ///      Any unredeemed shares remain in `_vaultShares` and are available next cycle.
    /// @param poolId   The pool to withdraw for.
    /// @param currency The currency to withdraw.
    function _withdrawAllFromVault(PoolId poolId, Currency currency) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return;
        uint256 shares = _vaultShares[poolId][currency];
        if (shares == 0) return;

        uint256 maxRedeemable = vault.maxRedeem(address(this));
        uint256 toRedeem = shares > maxRedeemable ? maxRedeemable : shares;
        if (toRedeem == 0) return;

        vault.redeem(toRedeem, address(this), address(this));
        _vaultShares[poolId][currency] -= toRedeem;
    }

    /// @dev Withdraw a specific asset amount from the pool's vault. Caps at available shares.
    ///      For pools without a vault, debits `_erc20` tracking instead (tokens already in hook).
    /// @param poolId   The pool to withdraw for.
    /// @param currency The currency to withdraw.
    /// @param amount   The target asset amount to withdraw.
    function _withdrawFromVault(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _erc20[poolId][currency] -= amount;
            return;
        }
        uint256 shares = vault.previewWithdraw(amount);
        uint256 poolShares = _vaultShares[poolId][currency];
        if (shares > poolShares) shares = poolShares;
        uint256 maxRedeemable = vault.maxRedeem(address(this));
        if (shares > maxRedeemable) shares = maxRedeemable;
        if (shares == 0) return;
        vault.redeem(shares, address(this), address(this));
        _vaultShares[poolId][currency] -= shares;
    }

    /// @dev Deposit all of the hook's ERC-20 balance for both currencies into their vaults.
    ///      Called in afterSwap after the JIT cycle resolves, to put assets back to work.
    /// @param poolId The pool whose assets to re-vault.
    /// @param key    The pool key (for currency references).
    function _depositAllToVaults(PoolId poolId, PoolKey calldata key) internal {
        _depositAllToVault(poolId, key.currency0);
        _depositAllToVault(poolId, key.currency1);
    }

    /// @dev Deposit the hook's entire ERC-20 balance of a currency into its vault.
    ///      If no vault is configured, records the balance in `_erc20` for per-pool tracking.
    ///      Vault shares received are credited to `_vaultShares[poolId]`.
    /// @param poolId   The pool this deposit belongs to.
    /// @param currency The currency to deposit.
    function _depositAllToVault(PoolId poolId, Currency currency) internal {
        uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _erc20[poolId][currency] += bal;
            return;
        }
        _ensureVaultApproval(currency, address(vault));
        uint256 shares = vault.deposit(bal, address(this));
        _vaultShares[poolId][currency] += shares;
    }

    /// @dev Set max approval for a vault if not already approved. After the first call,
    ///      subsequent deposits skip the approve SSTORE entirely (~46K gas savings per call).
    function _ensureVaultApproval(Currency currency, address vault) internal {
        IERC20Minimal token = IERC20Minimal(Currency.unwrap(currency));
        if (token.allowance(address(this), vault) == 0) {
            token.approve(vault, type(uint256).max);
        }
    }

    /// @dev Ensure the hook holds at least `amount` of ERC-20 for `currency`.
    ///
    ///      For vaulted pools: if the hook's current ERC-20 balance is insufficient, redeems
    ///      vault shares to cover the shortfall. Uses `previewWithdraw` to compute the exact
    ///      shares needed, capped at the pool's available vault shares.
    ///
    ///      For non-vaulted pools: debits `_erc20` tracking. The ERC-20 is already in the hook.
    ///
    /// @param poolId   The pool requiring the balance.
    /// @param currency The currency to ensure.
    /// @param amount   The minimum ERC-20 balance needed.
    function _ensureERC20(PoolId poolId, Currency currency, uint256 amount) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _erc20[poolId][currency] -= amount;
            return;
        }
        uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal >= amount) return;

        uint256 shares = vault.previewWithdraw(amount - bal);
        uint256 poolShares = _vaultShares[poolId][currency];
        if (shares > poolShares) shares = poolShares;
        vault.redeem(shares, address(this), address(this));
        _vaultShares[poolId][currency] -= shares;
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
    ///      After redemption, the ERC-20 is available for vault deposit or LP deployment.
    ///
    /// @param poolId   The pool whose claims to redeem.
    /// @param currency The currency to redeem claims for.
    function _redeemPoolClaims(PoolId poolId, Currency currency) internal {
        uint256 claimBal = _claims[poolId][currency];
        if (claimBal > 0) {
            _poolManager().burn(address(this), currency.toId(), claimBal);
            _poolManager().take(currency, address(this), claimBal);
            _claims[poolId][currency] = 0;
        }
    }

    /// @dev Record newly minted ERC-6909 claims for a pool. Called after `poolManager.mint()`
    ///      in the JIT delta resolution, when the hook has a positive delta that cannot be
    ///      settled as ERC-20 (the swapper hasn't paid yet).
    /// @param poolId   The pool the claims belong to.
    /// @param currency The currency of the claims.
    /// @param amount   The claim amount to record.
    function _recordClaims(PoolId poolId, Currency currency, uint256 amount) internal {
        _claims[poolId][currency] += amount;
    }

    /// @dev Zero out per-pool ERC-20 tracking for a currency. Called when all of a pool's
    ///      ERC-20 is deployed as LP (e.g., during JIT), so the tracking should reset.
    /// @param poolId   The pool to clear.
    /// @param currency The currency to clear.
    function _clearERC20Tracking(PoolId poolId, Currency currency) internal {
        _erc20[poolId][currency] = 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ABSTRACT: POOL MANAGER ACCESS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Subclasses must provide access to the v4 PoolManager. Required for claim
    ///      operations (`burn`, `take`) in `_redeemPoolClaims`. Typically returns
    ///      `poolManager` from the BaseHook inheritance chain.
    function _poolManager() internal view virtual returns (IPoolManager);
}
