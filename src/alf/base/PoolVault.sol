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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MultiAssetVault} from "./vault/MultiAssetVault.sol";
import {VaultId} from "../types/VaultId.sol";

/// @title PoolVault
/// @author Uniswap Labs
///
/// @notice Uniswap v4 hook adapter over `MultiAssetVault`. Adds the V4-specific concerns:
///         ERC-4626 vault rehypothecation, ERC-6909 PoolManager claim handling, and per-pool
///         tracking of raw ERC-20 attributed to the hook contract.
///
///         `MultiAssetVault` provides the share accounting, virtual-shares inflation defense,
///         and bootstrap/deposit/withdraw lifecycle. PoolVault overrides the three asset-I/O
///         hooks (`_pullAsset`, `_pushAsset`, `_assetBalance`) to plumb V4 currency types and
///         vault rehypothecation, and exposes `PoolKey`-flavored entry points so subclasses
///         (e.g., SmartPoolHook) integrate naturally.
///
///         For every `(PoolId, Currency)`, PoolVault tracks three asset sources:
///
///           1. **ERC4626 vault shares** -- assets rehypothecated into yield-bearing vaults
///              between swaps. Tracked per-pool via `_vaultShares` to isolate multi-pool
///              deployments that share the same vault contract.
///
///           2. **ERC-6909 claims** -- deferred settlement tokens minted on the PoolManager
///              when afterSwap produces a positive delta but the PM lacks ERC-20 (because the
///              swapper hasn't settled yet). Tracked per-pool via `_state.claims` and redeemed
///              in the next `_redeemPoolClaims`.
///
///           3. **Raw ERC-20** -- tokens held directly by the hook, attributed per-pool via
///              `_state.erc20`. Source of truth for pool ownership; the hook's global
///              `balanceOf` is never read for accounting decisions.
///
///         ## Token Compatibility
///
///         Inbound transfers (user → hook) use OZ `SafeERC20.safeTransferFrom`. Outbound
///         (hook → user) uses v4-core's `Currency.transfer`. Vault approvals use
///         `forceApprove` for tokens that require zero-out-first.
///
///         **Native ETH is NOT supported** -- subclasses must reject `address(0)` currencies
///         at pool initialization. PoolVault calls `IERC20.safeTransferFrom(address(0), ...)`
///         which would revert; the subclass-level rejection makes the failure mode explicit
///         at init.
///
/// @dev    See `MultiAssetVault` for the share-math + lifecycle. This contract is the V4
///         binding: it translates `PoolKey` / `PoolId` / `Currency` into the base's
///         `VaultId` / `address asset` plumbing, and adds the V4-specific helpers
///         (`_redeemPoolClaims`, `_recordClaims`, `_debitPoolERC20`) that the JIT lifecycle
///         in subclasses calls during swap callbacks.
/// @custom:security-contact security@uniswap.org
abstract contract PoolVault is MultiAssetVault {
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
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice ERC4626 vault for each (pool, currency) pair.
    /// @dev    `address(0)` means no vault is configured -- tokens are held as ERC-20 in the
    ///         hook and tracked via `_state.erc20`. Vaults are typically set at pool
    ///         initialization and are immutable for the pool's lifetime.
    mapping(PoolId => mapping(Currency => IERC4626)) public vaults;

    /// @dev Number of ERC4626 vault shares this pool owns. Isolated from other pools that
    ///      may use the same vault contract, preventing one pool from consuming another's
    ///      shares.
    mapping(PoolId => mapping(Currency => uint256)) internal _vaultShares;

    /// @dev Packed per-(pool, currency) ERC-20 + ERC-6909 claim state.
    ///
    ///      `state.erc20`  -- ERC-20 tokens held by the hook attributed to this pool.
    ///                       ALWAYS reflects the per-pool share of the hook's global token
    ///                       balance -- never substitutes a global `balanceOf` read.
    ///      `state.claims` -- ERC-6909 claims on the PoolManager attributed to this pool.
    ///                       Minted when afterSwap produces a positive hook delta; redeemed
    ///                       to ERC-20 in the next beforeSwap via `_redeemPoolClaims`.
    mapping(PoolId => mapping(Currency => CurrencyState)) internal _state;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The vault cannot satisfy the requested withdrawal amount (e.g., paused or capped).
    error VaultLiquidityShortfall();

    /// @dev A vault redemption returned more shares than the pool owns. Defensive check --
    ///      should never trigger if `_vaultShares` accounting is consistent.
    error CrossPoolShareLeak();

    /// @dev `_debitPoolERC20` was asked to pay more than the pool's tracked ERC-20 balance.
    error InsufficientPoolBalance();

    /// @dev `vault.deposit` returned zero shares for a non-zero asset deposit. Either the
    ///      vault enforces a minimum deposit threshold the pool's amount didn't meet, or the
    ///      vault is misconfigured. Reverting fail-fast prevents asset loss into a vault
    ///      that gives no claim back.
    error ZeroSharesMinted();

    // ═══════════════════════════════════════════════════════════════════════════
    //                  TYPED VIEWS (PoolKey / PoolId wrappers)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Total shares outstanding for a pool, across all depositors.
    /// @param poolId The pool whose share supply should be read.
    /// @return shares Total non-transferable pool shares outstanding.
    function totalShares(PoolId poolId) external view returns (uint256) {
        return _totalShares[_vaultIdFor(poolId)];
    }

    /// @notice Share balance for `(poolId, user)`.
    /// @param poolId The pool whose share ledger should be read.
    /// @param user The account whose share balance should be read.
    /// @return shares Non-transferable pool shares held by `user`.
    function userShares(PoolId poolId, address user) external view returns (uint256) {
        return _userShares[_vaultIdFor(poolId)][user];
    }

    /// @notice Returns the total managed assets for a pool across both currencies. Sums
    ///         vault assets (via `convertToAssets`), ERC-6909 claims, and per-pool ERC-20.
    /// @param key The PoolKey identifying the pool and its two currencies.
    /// @return amount0 Total managed currency0 assets, in currency0 native decimals.
    /// @return amount1 Total managed currency1 assets, in currency1 native decimals.
    function totalAssets(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1) {
        return _totalAssets(key);
    }

    /// @notice Preview the token amounts required to mint `shares` for a pool. Rounds up.
    /// @param key The PoolKey identifying the pool and its two currencies.
    /// @param shares The number of non-transferable pool shares to mint.
    /// @return amount0 Required currency0 amount, rounded up, in currency0 native decimals.
    /// @return amount1 Required currency1 amount, rounded up, in currency1 native decimals.
    function previewDeposit(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertToAmounts(
            _vaultIdFor(key.toId()), Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), shares, true
        );
    }

    /// @notice Preview the token amounts returned for burning `shares` from a pool. Rounds down.
    /// @param key The PoolKey identifying the pool and its two currencies.
    /// @param shares The number of non-transferable pool shares to burn.
    /// @return amount0 Returned currency0 amount, rounded down, in currency0 native decimals.
    /// @return amount1 Returned currency1 amount, rounded down, in currency1 native decimals.
    function previewWithdraw(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertToAmounts(
            _vaultIdFor(key.toId()), Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), shares, false
        );
    }

    /// @dev Wrap a `PoolId` into the base's `VaultId` namespace. Info-lossless cast
    ///      through bytes32; both types are `type X is bytes32`.
    function _vaultIdFor(PoolId poolId) internal pure returns (VaultId) {
        return VaultId.wrap(PoolId.unwrap(poolId));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              PoolKey-FLAVORED LIFECYCLE (adapters into base)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev See {MultiAssetVault._bootstrap}. Adapter over PoolKey/Currency.
    function _bootstrap(PoolKey calldata key, address from, address to, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 sharesMinted)
    {
        return _bootstrap(
            _vaultIdFor(key.toId()),
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            from,
            to,
            amount0,
            amount1
        );
    }

    /// @dev See {MultiAssetVault._deposit}. Asset pair is read from the base's `_assets`
    ///      storage (set at bootstrap), not threaded through here.
    function _deposit(PoolKey calldata key, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        return _deposit(_vaultIdFor(key.toId()), from, to, shares);
    }

    /// @dev See {MultiAssetVault._withdraw}.
    function _withdraw(PoolKey calldata key, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        return _withdraw(_vaultIdFor(key.toId()), from, to, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ASSET ACCOUNTING (V4)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Total managed assets for a pool across both currencies.
    function _totalAssets(PoolKey memory key) internal view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        amount0 = _assetBalanceV4(poolId, key.currency0);
        amount1 = _assetBalanceV4(poolId, key.currency1);
    }

    /// @dev Total managed balance for a single (pool, currency) pair. Sums three sources:
    ///      ERC4626 vault assets (via `convertToAssets`), ERC-6909 claims, and per-pool
    ///      ERC-20 holdings.
    ///
    ///      DELIBERATE CAP-ASYMMETRY (do NOT "fix"): this function does NOT cap the vault
    ///      contribution by `maxWithdraw`, while `_effectiveBalance` does. The asymmetry
    ///      is load-bearing for share math — LP shares represent the pool's TOTAL economic
    ///      claim, including capital temporarily locked in a paused, capped, or
    ///      utilization-constrained vault. Capping here would let vault throttling reduce
    ///      LP exit value even though the pool's underlying stake is unchanged. Callers
    ///      that want the immediately-withdrawable subset (JIT deployment sizing, indicative
    ///      quotes) MUST use `_effectiveBalance` instead.
    ///
    ///      The trade-off: a vault that overstates `convertToAssets` (unrealised yield not
    ///      actually withdrawable, buggy/adversarial vault) inflates `_assetBalanceV4` →
    ///      inflates `previewDeposit`/`previewWithdraw` → dilutes new depositors and may
    ///      brick withdrawals at `_ensureERC20`'s maxWithdraw cap. This is bounded by the
    ///      documented vault-trust assumption: operators must use trusted ERC-4626 vaults.
    function _assetBalanceV4(PoolId poolId, Currency currency) internal view returns (uint256 bal) {
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
    ///      `_assetBalanceV4`, but caps the vault contribution at this pool's PRO-RATA share
    ///      of `vault.maxWithdraw(this)` so callers requesting "what can be deployed right
    ///      now" see the truth even when the vault is paused, capped, or
    ///      utilization-constrained.
    ///
    ///      Pro-rata cap detail: `maxWithdraw(this)` is hook-wide across all pools sharing
    ///      this vault. A naive cap at the global value would let pool A see liquidity that
    ///      actually belongs to pool B (or vice versa), enabling cross-pool DoS during vault
    ///      utilization spikes. The fix scales the global cap by this pool's share of total
    ///      hook-held vault shares: `poolMax = globalMax * poolShares / totalVaultShares`.
    function _effectiveBalance(PoolId poolId, Currency currency) internal view returns (uint256 bal) {
        CurrencyState storage s = _state[poolId][currency];
        bal = uint256(s.erc20) + uint256(s.claims);
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) != address(0)) {
            uint256 shares = _vaultShares[poolId][currency];
            if (shares > 0) {
                uint256 byConvert = vault.convertToAssets(shares);
                uint256 globalMax = vault.maxWithdraw(address(this));
                uint256 totalHookShares = IERC20(address(vault)).balanceOf(address(this));
                uint256 poolMax = totalHookShares > 0 ? FullMath.mulDiv(globalMax, shares, totalHookShares) : 0;
                bal += byConvert < poolMax ? byConvert : poolMax;
            }
        }
    }

    /// @dev Pool-level effective (immediately-withdrawable) assets across both currencies.
    function _effectiveAssets(PoolKey calldata key) internal view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        amount0 = _effectiveBalance(poolId, key.currency0);
        amount1 = _effectiveBalance(poolId, key.currency1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              ABSTRACT-HOOK OVERRIDES (MultiAssetVault → V4)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc MultiAssetVault
    /// @dev Pulls underlying ERC-20 from `from` via `safeTransferFrom`, measures the actual
    ///      receipt (FoT/rebasing token defense), then routes:
    ///        - If a vault is configured for this `(pool, currency)`, deposits to the vault
    ///          (updating `_vaultShares`).
    ///        - Otherwise, credits the per-pool `_state.erc20` counter.
    function _pullAsset(VaultId vaultId, address asset, address from, uint256 want)
        internal
        override
        returns (uint256 received)
    {
        if (want == 0) return 0;
        PoolId poolId = PoolId.wrap(VaultId.unwrap(vaultId));
        Currency currency = Currency.wrap(asset);

        // Measure inbound receipt against the hook's balance, NOT the vault's, so FoT and
        // rebasing tokens are reconciled before any vault interaction.
        IERC20 token = IERC20(asset);
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), want);
        received = token.balanceOf(address(this)) - balBefore;
        if (received == 0) return 0;

        // Route to vault if configured; otherwise track in `_state.erc20`.
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            CurrencyState storage s = _state[poolId][currency];
            s.erc20 = (uint256(s.erc20) + received).toUint128();
        } else {
            _depositToVault(poolId, currency, received);
        }
    }

    /// @inheritdoc MultiAssetVault
    /// @dev Ensures the per-pool `_state.erc20` holds at least `amount` -- redeems claims
    ///      and/or withdraws from the configured vault as needed -- then transfers via
    ///      `Currency.transfer` (USDT-safe).
    function _pushAsset(VaultId vaultId, address asset, address to, uint256 amount) internal override {
        if (amount == 0) return;
        PoolId poolId = PoolId.wrap(VaultId.unwrap(vaultId));
        Currency currency = Currency.wrap(asset);

        _ensureERC20(poolId, currency, amount);
        currency.transfer(to, amount);
    }

    /// @inheritdoc MultiAssetVault
    /// @dev Sums the per-(pool, currency) ERC-4626 vault assets (via `convertToAssets`),
    ///      ERC-6909 claims, and tracked ERC-20.
    function _assetBalance(VaultId vaultId, address asset) internal view override returns (uint256) {
        return _assetBalanceV4(PoolId.wrap(VaultId.unwrap(vaultId)), Currency.wrap(asset));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: VAULT OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deposit `amount` of `currency` into the pool's configured ERC4626 vault. Caller
    ///      must have already transferred `amount` tokens to this contract. If no vault is
    ///      configured, the amount is tracked in `_state.erc20` instead. Assumes the vault
    ///      is already approved (subclasses approve at pool init via `_approveVault`).
    ///
    ///      ## Vault trust model
    ///
    ///      The hook holds standing max allowance to each (pool, currency) vault. A
    ///      compromised or upgradeable vault for currency X can in principle `transferFrom`
    ///      the hook's full balance of X -- including raw ERC-20 attributed to unrelated
    ///      pools that share that currency. Operators MUST select vaults whose security
    ///      properties they understand (immutable / non-upgradeable preferred).
    function _depositToVault(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            CurrencyState storage s = _state[poolId][currency];
            s.erc20 = (uint256(s.erc20) + amount).toUint128();
            return;
        }

        // Pre-credit predicted shares so view callers during a vault callback (e.g.,
        // `getReserves`, `previewWithdraw`, `getIndicativeQuote`) observe a coherent total.
        uint256 sharesPredicted = vault.convertToShares(amount);
        _vaultShares[poolId][currency] += sharesPredicted;

        _ensureVaultAllowance(currency, address(vault), amount);
        uint256 sharesActual = vault.deposit(amount, address(this));

        // Fail-fast on a vault that swallows assets without minting shares.
        if (sharesActual == 0) revert ZeroSharesMinted();

        // Reconcile predicted-vs-actual divergence.
        if (sharesActual != sharesPredicted) {
            if (sharesActual > sharesPredicted) {
                _vaultShares[poolId][currency] += (sharesActual - sharesPredicted);
            } else {
                _vaultShares[poolId][currency] -= (sharesPredicted - sharesActual);
            }
        }
    }

    /// @dev Deposit all of the pool's tracked ERC-20 balance for both currencies into vaults.
    ///      Called in afterSwap after the JIT cycle resolves.
    function _depositAllToVaults(PoolId poolId, PoolKey calldata key) internal {
        _depositAllToVault(poolId, key.currency0);
        _depositAllToVault(poolId, key.currency1);
    }

    /// @dev Deposit the pool's tracked ERC-20 balance of a currency into its vault. No-op
    ///      for non-vaulted pools (the balance stays in `_state.erc20`). Pre-credits
    ///      `_vaultShares` to keep view callers coherent through the deposit callback.
    function _depositAllToVault(PoolId poolId, Currency currency) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return;
        CurrencyState storage s = _state[poolId][currency];
        uint256 amount = s.erc20;
        if (amount == 0) return;

        uint256 sharesPredicted = vault.convertToShares(amount);
        s.erc20 = 0;
        _vaultShares[poolId][currency] += sharesPredicted;

        _ensureVaultAllowance(currency, address(vault), amount);
        uint256 sharesActual = vault.deposit(amount, address(this));
        if (sharesActual == 0) revert ZeroSharesMinted();

        if (sharesActual != sharesPredicted) {
            if (sharesActual > sharesPredicted) {
                _vaultShares[poolId][currency] += (sharesActual - sharesPredicted);
            } else {
                _vaultShares[poolId][currency] -= (sharesPredicted - sharesActual);
            }
        }
    }

    /// @dev Withdraw `amount` of `currency` from the pool's vault, crediting per-pool ERC-20.
    ///      Caps at `vault.maxWithdraw` to handle paused or utilization-constrained vaults
    ///      gracefully.
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
    ///      Withdraws from the vault for any shortfall, reverts with `VaultLiquidityShortfall`
    ///      if the vault can't cover.
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
            // Non-vaulted pool with insufficient erc20 -- underflow reverts cleanly below.
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

    /// @dev Set max approval for a vault using OZ `forceApprove` (zeros out first for
    ///      USDT-style tokens). Subclasses MUST call this once per (currency, vault) pair
    ///      at pool initialization, before any vault deposit can occur.
    function _approveVault(Currency currency, address vault) internal {
        if (vault == address(0)) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), vault) == 0) {
            token.forceApprove(vault, type(uint256).max);
        }
    }

    /// @dev Ensure the hook's allowance to `vault` for `currency` is at least `amount` for the
    ///      current operation. Refreshes to `type(uint256).max` only when below the required
    ///      threshold — a no-op for tokens that don't decrement allowance on transfer (the
    ///      common case), and a recovery path for USDT-style tokens whose post-init
    ///      max-allowance is gradually consumed by ordinary deposits.
    ///
    ///      Without this guard, the JIT cycle would brick on the first deposit after the
    ///      cumulative deposit volume crossed `type(uint256).max` — no real-world threshold,
    ///      but unbounded for tokens that decrement on every transfer (USDT) and bricks the
    ///      pool until owner manually calls `refreshVaultApproval`.
    function _ensureVaultAllowance(Currency currency, address vault, uint256 amount) internal {
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), vault) < amount) {
            token.forceApprove(vault, type(uint256).max);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: CLAIM MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Redeem this pool's ERC-6909 claims to ERC-20 via the PoolManager. Only callable
    ///      within a v4 unlock context. Increments `_state.erc20` by the redeemed amount and
    ///      returns the post-redeem balance so callers don't need a follow-up SLOAD.
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
    ///      in the JIT delta resolution.
    function _recordClaims(PoolId poolId, Currency currency, uint256 amount) internal {
        CurrencyState storage s = _state[poolId][currency];
        s.claims = (uint256(s.claims) + amount).toUint128();
    }

    /// @dev Debit `amount` from the pool's tracked ERC-20 balance after a PM settlement.
    ///      The actual `_settle` call is the subclass's responsibility -- this function only
    ///      updates the per-pool counter.
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
    ///      operations (`burn`, `take`) in `_redeemPoolClaims`.
    function _poolManager() internal view virtual returns (IPoolManager);
}
