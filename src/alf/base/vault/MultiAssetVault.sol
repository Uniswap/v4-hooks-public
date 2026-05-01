// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {VaultId} from "../../types/VaultId.sol";

/// @title MultiAssetVault
/// @author Uniswap Labs
/// @notice Generic two-asset share-accounting primitive. Tracks proportional shares of an
///         abstract `(asset0, asset1)` pair indexed by an opaque `VaultId`.
///
///         Shares are non-transferable internal accounting -- there is no ERC-20 share
///         token. Each vault id has its own supply (`totalShares`) and per-user balance
///         (`userShares`). Conversion math uses the EIP-4626 virtual-shares pattern:
///
///             amount = shares * (total + 1) / (supply + 10**_decimalsOffset())
///
///         The `+1` virtual asset and `+10**offset` virtual shares exist only in math --
///         they don't correspond to real entries and can never withdraw. They make
///         post-bootstrap inflation attacks (e.g., direct donations to an underlying
///         yield source that the subclass reads through `_assetBalance`) uneconomic
///         regardless of bootstrap size: any donation is captured proportionally by the
///         virtual position.
///
///         Lifecycle:
///           - First deposit goes through `_bootstrap`, mints `sqrt(received0 * received1)`
///             shares all credited to the bootstrapper. The bootstrap amounts set the
///             initial share-asset ratio.
///           - Subsequent deposits / withdraws go through `_deposit` / `_withdraw`. Deposits
///             round UP (depositor pays slightly more); withdrawals round DOWN (withdrawer
///             receives slightly less). Same-block deposit-then-withdraw on the same
///             `(vaultId, user)` is rejected to defend against atomic fee/yield sniping.
///
///         The base owns the share state, the share math, and the lifecycle. Subclasses
///         own asset I/O via three hooks:
///
///           - `_pullAsset(vaultId, asset, from, want) -> received`: pull tokens; return
///             actual received amount (FoT measurement is the subclass's responsibility).
///           - `_pushAsset(vaultId, asset, to, amount)`: push tokens to `to`; subclass is
///             free to source from raw balance, ERC-4626 vault, etc.
///           - `_assetBalance(vaultId, asset) -> uint256`: read total managed assets for
///             the (vault, asset) pair. The conversion math reads this for both legs.
///
/// @dev    This primitive is reentrancy-AGNOSTIC. Subclasses are responsible for guarding
///         their own external entry points (typically with `nonReentrant` plus a JIT-cycle
///         lock if applicable). The internal lifecycle is effects-first where possible:
///         share counters are updated before asset I/O so reentrant view paths see a
///         coherent snapshot.
/// @custom:security-contact security@uniswap.org
abstract contract MultiAssetVault is BlockNumberish {
    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Total shares outstanding for a vault, across all depositors. Real depositor
    ///      shares only; conversion math reads `supply + 10**_decimalsOffset()` to add
    ///      virtual shares for inflation defense. Subclasses expose typed getters (e.g.,
    ///      `PoolVault.totalShares(PoolId)`) over this internal storage.
    mapping(VaultId vaultId => uint256) internal _totalShares;

    /// @dev Share balance for each (vaultId, user) pair. Numerator for a user's
    ///      proportional claim on vault assets.
    mapping(VaultId vaultId => mapping(address user => uint256)) internal _userShares;

    /// @dev Block number of the last `_deposit` for each (vaultId, user). `_withdraw`
    ///      reverts when called in the same block, defending against atomic fee/yield
    ///      sniping. Read via `_getBlockNumberish()` (Uniswap's `BlockNumberish`) so the
    ///      value reflects the chain's fastest block clock; on Arbitrum One, `block.number`
    ///      returns the L1 block number which makes many sequencer transactions share the
    ///      same value, defeating the lock.
    mapping(VaultId vaultId => mapping(address user => uint256)) internal _lastDepositBlock;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted on first deposit (bootstrap) -- sets the initial share/asset ratio.
    /// @param vaultId  The vault being bootstrapped.
    /// @param provider The address that received the bootstrap shares.
    /// @param shares   Total shares minted (`sqrt(received0 * received1)`).
    /// @param amount0  Asset0 transferred from the bootstrapper (post-FoT receipt).
    /// @param amount1  Asset1 transferred from the bootstrapper (post-FoT receipt).
    event Bootstrap(
        VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when a depositor mints shares by providing proportional token amounts.
    event Deposit(
        VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when a depositor burns shares and receives proportional token amounts.
    event Withdraw(
        VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1
    );

    // ═══════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The caller attempted to burn more shares than they hold.
    error InsufficientShares();
    /// @dev `_deposit` was called before the vault was bootstrapped via `_bootstrap`.
    error VaultNotBootstrapped();
    /// @dev `_bootstrap` was called for a vault that already has shares.
    error VaultAlreadyBootstrapped();
    /// @dev Bootstrap amounts produce zero shares (one or both received amounts is zero).
    error InsufficientBootstrap();
    /// @dev `_withdraw` was called in the same block as the depositor's last `_deposit`.
    ///      Prevents atomic deposit-swap-withdraw fee/yield sniping.
    error SameBlockWithdraw();
    /// @dev `_pullAsset` for a deposit/bootstrap delivered fewer tokens than requested
    ///      (typically a fee-on-transfer or rebasing token). The deposit path mints shares
    ///      against the requested amount, so accepting under-receipt would dilute existing
    ///      shareholders. Subclasses that want to support FoT/rebasing tokens must
    ///      compensate within `_pullAsset` (e.g., by topping up).
    error TransferReceiptShortfall();

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: BOOTSTRAP
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Seed the vault with the first deposit. Mints `sqrt(received0 * received1)`
    ///      shares to `to` and sets the initial share/asset ratio. Caller is responsible
    ///      for authorization (typically owner-only on the consuming subclass).
    /// @param vaultId The vault to bootstrap.
    /// @param asset0  First asset address. Subclass-defined identifier used by `_pullAsset`.
    /// @param asset1  Second asset address.
    /// @param from    The address to pull tokens from (passed to `_pullAsset`).
    /// @param to      The address to credit shares to.
    /// @param amount0 Asset0 to deposit.
    /// @param amount1 Asset1 to deposit.
    /// @return sharesMinted Total shares minted, all credited to `to`.
    function _bootstrap(
        VaultId vaultId,
        address asset0,
        address asset1,
        address from,
        address to,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 sharesMinted) {
        if (_totalShares[vaultId] != 0) revert VaultAlreadyBootstrapped();
        if (amount0 == 0 || amount1 == 0) revert InsufficientBootstrap();

        // FoT/rebasing reconciliation is the subclass's responsibility inside `_pullAsset`.
        // The share math uses the returned `received` so any under-receipt translates to
        // smaller bootstrap shares rather than silent share dilution.
        uint256 received0 = _pullAsset(vaultId, asset0, from, amount0);
        uint256 received1 = _pullAsset(vaultId, asset1, from, amount1);
        if (received0 == 0 || received1 == 0) revert InsufficientBootstrap();

        sharesMinted = FixedPointMathLib.sqrt(received0 * received1);
        if (sharesMinted == 0) revert InsufficientBootstrap();

        _totalShares[vaultId] = sharesMinted;
        _userShares[vaultId][to] = sharesMinted;
        _lastDepositBlock[vaultId][to] = _getBlockNumberish();

        emit Bootstrap(vaultId, to, sharesMinted, received0, received1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Mint `shares` to `to` by pulling proportional token amounts from `from`. The
    ///      conversion rounds UP per the virtual-offset formula -- depositor pays slightly
    ///      more to prevent share-value dilution.
    function _deposit(
        VaultId vaultId,
        address asset0,
        address asset1,
        address from,
        address to,
        uint256 shares
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (_totalShares[vaultId] == 0) revert VaultNotBootstrapped();

        (uint256 want0, uint256 want1) = _convertToAmounts(vaultId, asset0, asset1, shares, true);

        // Effects-first: share counters update before any asset I/O so a reentrant view
        // path (e.g., a callback observing `previewDeposit`) sees a coherent snapshot.
        _totalShares[vaultId] += shares;
        _userShares[vaultId][to] += shares;
        _lastDepositBlock[vaultId][to] = _getBlockNumberish();

        // Shares are minted against `want{0,1}`, so any FoT/rebasing under-receipt would
        // dilute existing shareholders by leaving the vault short on assets. Fail-fast on
        // under-receipt -- subclasses that want to support FoT must compensate inside
        // `_pullAsset` (e.g., by pre-funding the difference).
        amount0 = want0 > 0 ? _pullAsset(vaultId, asset0, from, want0) : 0;
        amount1 = want1 > 0 ? _pullAsset(vaultId, asset1, from, want1) : 0;
        if (amount0 < want0 || amount1 < want1) revert TransferReceiptShortfall();

        emit Deposit(vaultId, to, shares, amount0, amount1);
    }

    /// @dev Burn `shares` from `from` and send proportional token amounts to `to`. The
    ///      conversion rounds DOWN -- withdrawer receives slightly less to prevent
    ///      over-withdrawal at remaining shareholders' expense.
    function _withdraw(
        VaultId vaultId,
        address asset0,
        address asset1,
        address from,
        address to,
        uint256 shares
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (_getBlockNumberish() == _lastDepositBlock[vaultId][from]) revert SameBlockWithdraw();
        if (_userShares[vaultId][from] < shares) revert InsufficientShares();

        (amount0, amount1) = _convertToAmounts(vaultId, asset0, asset1, shares, false);

        _totalShares[vaultId] -= shares;
        _userShares[vaultId][from] -= shares;

        if (amount0 > 0) _pushAsset(vaultId, asset0, to, amount0);
        if (amount1 > 0) _pushAsset(vaultId, asset1, to, amount1);

        emit Withdraw(vaultId, from, shares, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: SHARE MATH
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Convert a share amount to the equivalent token amounts for both assets,
    ///      proportional to the vault's current total balances. Uses the EIP-4626
    ///      virtual-offset formula:
    ///
    ///          amount = shares * (total + 1) / (supply + 10**_decimalsOffset())
    ///
    ///      Reverts if `supply == 0` -- pre-bootstrap vaults have no defined ratio.
    function _convertToAmounts(
        VaultId vaultId,
        address asset0,
        address asset1,
        uint256 shares,
        bool roundUp
    ) internal view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = _totalShares[vaultId];
        if (supply == 0) revert VaultNotBootstrapped();

        uint256 effSupply = supply + 10 ** _decimalsOffset();
        uint256 total0 = _assetBalance(vaultId, asset0);
        uint256 total1 = _assetBalance(vaultId, asset1);
        if (roundUp) {
            amount0 = FixedPointMathLib.fullMulDivUp(shares, total0 + 1, effSupply);
            amount1 = FixedPointMathLib.fullMulDivUp(shares, total1 + 1, effSupply);
        } else {
            amount0 = FixedPointMathLib.fullMulDiv(shares, total0 + 1, effSupply);
            amount1 = FixedPointMathLib.fullMulDiv(shares, total1 + 1, effSupply);
        }
    }

    /// @notice Number of "virtual shares" decimal places used in the inflation defense.
    ///         The conversion math reads `supply + 10**_decimalsOffset()` so an attacker's
    ///         post-bootstrap donation is diluted across the virtual position.
    /// @dev    Default: 12 (1e12 virtual shares). Strong defense regardless of bootstrap
    ///         size; conversion math drifts ~1 ppb from strict proportional values.
    ///         Subclasses MAY override to match a different decimal regime.
    function _decimalsOffset() internal view virtual returns (uint8) {
        return 12;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ABSTRACT HOOKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Pull `want` of `asset` from `from` into the vault's custody, returning the
    ///      actual amount received. Subclasses are responsible for the transfer mechanism
    ///      (e.g., `IERC20.safeTransferFrom` + balance-delta measurement) and any
    ///      post-receipt routing (e.g., depositing to an ERC-4626 yield source). The
    ///      returned `received` is what the share math uses, so FoT/rebasing reconciliation
    ///      lives here.
    function _pullAsset(VaultId vaultId, address asset, address from, uint256 want)
        internal
        virtual
        returns (uint256 received);

    /// @dev Push `amount` of `asset` from the vault's custody to `to`. Subclasses are
    ///      responsible for sourcing the asset (raw balance, ERC-4626 withdrawal, claim
    ///      redemption, etc.) and the actual transfer.
    function _pushAsset(VaultId vaultId, address asset, address to, uint256 amount) internal virtual;

    /// @dev Read the vault's total managed balance of `asset`. Used by `_convertToAmounts`
    ///      for both legs. Subclasses sum whatever balance sources they manage (e.g.,
    ///      raw ERC-20 + ERC-6909 claims + ERC-4626 vault holdings).
    function _assetBalance(VaultId vaultId, address asset) internal view virtual returns (uint256);
}
