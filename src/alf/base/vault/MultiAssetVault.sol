// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {MultiAssetShareMath} from "./MultiAssetShareMath.sol";
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
///             amount = shares * (total + 1) / (supply + 10**_decimalsOffset(vaultId))
///
///         The `+1` virtual asset and `+10**offset` virtual shares exist only in math --
///         they don't correspond to real entries and can never withdraw. They mitigate
///         post-bootstrap donation attacks: any direct donation to an underlying yield
///         source that the subclass reads through `_assetBalance` is captured
///         proportionally by the virtual position.
///
///         **Bootstrap drift.** The bootstrapper's economic claim on the pool's value is
///         `S / (S + 10**offset)` where `S = sqrt(received0 * received1)`. When `S` is
///         comparable to or smaller than `10**offset`, the bootstrapper PERMANENTLY loses
///         a meaningful fraction of their seed capital to the virtual position. With the
///         default `_decimalsOffset = 12`, drift breakpoints look like:
///
///             | Bootstrap (each side, 6dec)   | shares S | drift |
///             |-------------------------------|---------:|------:|
///             | 1 wei                         |     1    |   ~1  |
///             | 1 USDC (1e6 wei)              |    1e6   |   ~1  |
///             | 1k USDC (1e9 wei)             |    1e9   |  ~99% |
///             | 1M USDC (1e12 wei)            |    1e12  |   50% |
///             | 100M USDC (1e14 wei)          |    1e14  | 1ppm  |
///             | Bootstrap (each side, 18dec)  | shares S | drift |
///             | 1 wei                         |     1    |   ~1  |
///             | 1 token (1e18 wei)            |    1e18  | 1ppb  |
///             | 1k token (1e21 wei)           |    1e21  |  ~0   |
///
///         For ~ppm-or-better drift, operators MUST seed with `S >= 100 * 10**offset`.
///         The base enforces this floor at bootstrap with `BootstrapTooSmall`. Subclasses
///         that handle low-decimal pairs SHOULD override `_decimalsOffset(vaultId)` to
///         lower the offset (e.g., to 6 for stablecoin pairs).
///
///         Lifecycle:
///           - First deposit goes through `_bootstrap`, mints `sqrt(received0 * received1)`
///             shares all credited to the bootstrapper. The bootstrap amounts set the
///             initial share-asset ratio.
///           - Subsequent deposits / withdraws go through `_deposit` / `_withdraw`. Deposits
///             round UP (depositor pays slightly more); withdrawals round DOWN (withdrawer
///             receives slightly less). A configurable per-vault `_minDepositBlocks(vaultId)`
///             lock rejects withdrawals that arrive earlier than
///             `lastDepositBlock + _minDepositBlocks(vaultId)` (measured on the
///             `BlockNumberish` clock) to defend against atomic fee/yield sniping. The
///             default implementation returns `0`, which means NO lock -- same-block
///             deposit-then-withdraw is allowed. Subclasses that need the legacy same-block
///             ban override `_minDepositBlocks` to return `1`; values `> 1` enforce a
///             longer lock.
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
    /// @dev Asset pair backing each vault, set at first bootstrap. Immutable thereafter --
    ///      `_bootstrap` reverts on a re-bootstrap, so the pair never changes once set.
    struct Assets {
        address asset0;
        address asset1;
    }

    mapping(VaultId vaultId => Assets) internal _assets;

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
    ///      reverts until `_getBlockNumberish() >= lastDepositBlock + _minDepositBlocks(vaultId)`,
    ///      defending against atomic fee/yield sniping. Read via `BlockNumberish` so the value
    ///      reflects the chain's fastest block clock; on Arbitrum One, `block.number` returns the
    ///      L1 block number which makes many sequencer transactions share the same value, which
    ///      would defeat the lock.
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
    /// @param vaultId  The vault receiving the deposit.
    /// @param provider The address that received the minted shares.
    /// @param shares   Shares minted to `provider`.
    /// @param amount0  Asset0 transferred from the depositor (post-FoT receipt).
    /// @param amount1  Asset1 transferred from the depositor (post-FoT receipt).
    event Deposit(VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a depositor burns shares and receives proportional token amounts.
    /// @param vaultId  The vault being withdrawn from.
    /// @param provider The address whose shares were burned.
    /// @param shares   Shares burned from `provider`.
    /// @param amount0  Asset0 transferred to the withdrawer.
    /// @param amount1  Asset1 transferred to the withdrawer.
    event Withdraw(VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);

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
    /// @dev `_withdraw` was called before the depositor's lock duration elapsed
    ///      (`_getBlockNumberish() < lastDepositBlock + _minDepositBlocks(vaultId)`).
    ///      Prevents atomic deposit-swap-withdraw fee/yield sniping.
    /// @param unlockBlock The `BlockNumberish`-clock block at which the lock clears.
    error DepositLocked(uint256 unlockBlock);
    /// @dev `_pullAsset` for a deposit/bootstrap delivered fewer tokens than requested
    ///      (typically a fee-on-transfer or rebasing token). The deposit path mints shares
    ///      against the requested amount, so accepting under-receipt would dilute existing
    ///      shareholders. Subclasses that want to support FoT/rebasing tokens must
    ///      compensate within `_pullAsset` (e.g., by topping up).
    error TransferReceiptShortfall();

    /// @dev Bootstrap shares (`sqrt(received0 * received1)`) are below the inflation-defense
    ///      floor of `100 * 10**_decimalsOffset(vaultId)`. Below this floor, the bootstrapper
    ///      PERMANENTLY loses more than ~1% of their seed capital to the virtual position.
    ///      Operators MUST seed with larger bootstrap amounts; the floor guarantees drift
    ///      stays below ~1%.
    /// @param sharesMinted The bootstrap shares the operator's amounts would have produced.
    /// @param minShares    The minimum shares the offset requires (`100 * 10**offset`).
    error BootstrapTooSmall(uint256 sharesMinted, uint256 minShares);

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

        // Bind the vault to its asset pair; subsequent operations read from this storage
        // rather than re-accepting the pair on every call. Defense against the subclass
        // accidentally passing a different pair on later operations.
        _assets[vaultId] = Assets({asset0: asset0, asset1: asset1});

        // FoT/rebasing reconciliation is the subclass's responsibility inside `_pullAsset`.
        // The share math uses the returned `received` so any under-receipt translates to
        // smaller bootstrap shares rather than silent share dilution.
        uint256 received0 = _pullAsset(vaultId, asset0, from, amount0);
        uint256 received1 = _pullAsset(vaultId, asset1, from, amount1);
        if (received0 == 0 || received1 == 0) revert InsufficientBootstrap();

        sharesMinted = MultiAssetShareMath.bootstrapShares(received0, received1);
        if (sharesMinted == 0) revert InsufficientBootstrap();

        // Inflation-defense floor: bootstrap shares must dwarf the virtual position so the
        // bootstrapper's economic claim is close to 100%. `100 * 10**offset` corresponds to
        // ~1% drift; below that, the bootstrapper permanently loses non-trivial seed capital
        // to the virtual position, AND a subsequent attacker can cheaply capture remaining
        // value via small `_deposit` calls (the EIP-4626 inflation defense protects future
        // depositors from EACH OTHER, not the bootstrapper themselves).
        uint256 minShares = 100 * 10 ** uint256(_decimalsOffset(vaultId));
        if (sharesMinted < minShares) revert BootstrapTooSmall(sharesMinted, minShares);

        // Pre-mutation accounting checkpoint. At bootstrap the vault holds no shares, so the
        // pre-state is (0, 0) -- an incentive capability initializes the bootstrapper's paid
        // index here and accrues from now.
        _onShareCheckpoint(vaultId, to, 0, 0);

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
    ///      more to prevent share-value dilution. The asset pair is read from `_assets`
    ///      (set at bootstrap) so the caller can't accidentally pass a different pair.
    function _deposit(VaultId vaultId, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        if (_totalShares[vaultId] == 0) revert VaultNotBootstrapped();

        Assets memory pair = _assets[vaultId];
        (uint256 want0, uint256 want1) = _convertToAmounts(vaultId, pair.asset0, pair.asset1, shares, true);

        // Settle reward/accounting accrual on the pre-deposit balances before the counters move.
        _onShareCheckpoint(vaultId, to, _totalShares[vaultId], _userShares[vaultId][to]);

        // Effects-first: share counters update before any asset I/O so a reentrant view
        // path (e.g., a callback observing `previewDeposit`) sees a coherent snapshot.
        _totalShares[vaultId] += shares;
        _userShares[vaultId][to] += shares;
        _lastDepositBlock[vaultId][to] = _getBlockNumberish();

        // Shares are minted against `want{0,1}`, so any FoT/rebasing under-receipt would
        // dilute existing shareholders by leaving the vault short on assets. Fail-fast on
        // under-receipt -- subclasses that want to support FoT must compensate inside
        // `_pullAsset` (e.g., by pre-funding the difference).
        amount0 = want0 > 0 ? _pullAsset(vaultId, pair.asset0, from, want0) : 0;
        amount1 = want1 > 0 ? _pullAsset(vaultId, pair.asset1, from, want1) : 0;
        if (amount0 < want0 || amount1 < want1) revert TransferReceiptShortfall();

        emit Deposit(vaultId, to, shares, amount0, amount1);
    }

    /// @dev Burn `shares` from `from` and send proportional token amounts to `to`. The
    ///      conversion rounds DOWN -- withdrawer receives slightly less to prevent
    ///      over-withdrawal at remaining shareholders' expense.
    function _withdraw(VaultId vaultId, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 unlockBlock = _lastDepositBlock[vaultId][from] + _minDepositBlocks(vaultId);
        if (_getBlockNumberish() < unlockBlock) revert DepositLocked(unlockBlock);
        if (_userShares[vaultId][from] < shares) revert InsufficientShares();

        Assets memory pair = _assets[vaultId];
        (amount0, amount1) = _convertToAmounts(vaultId, pair.asset0, pair.asset1, shares, false);

        // Settle reward/accounting accrual on the pre-withdraw balances before the counters move.
        _onShareCheckpoint(vaultId, from, _totalShares[vaultId], _userShares[vaultId][from]);

        _totalShares[vaultId] -= shares;
        _userShares[vaultId][from] -= shares;

        if (amount0 > 0) _pushAsset(vaultId, pair.asset0, to, amount0);
        if (amount1 > 0) _pushAsset(vaultId, pair.asset1, to, amount1);

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
    function _convertToAmounts(VaultId vaultId, address asset0, address asset1, uint256 shares, bool roundUp)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 supply = _totalShares[vaultId];
        if (supply == 0) revert VaultNotBootstrapped();

        return MultiAssetShareMath.convertToAmounts(
            shares,
            _assetBalance(vaultId, asset0),
            _assetBalance(vaultId, asset1),
            supply,
            _decimalsOffset(vaultId),
            roundUp
        );
    }

    /// @notice Number of "virtual shares" decimal places used in the inflation defense for a
    ///         specific vault. The conversion math reads `supply + 10**_decimalsOffset(vaultId)`
    ///         so an attacker's post-bootstrap donation is diluted across the virtual position.
    /// @dev    Default: `12` for every vault (1e12 virtual shares). The relationship between
    ///         the offset and the bootstrapper's drift is approximately
    ///         `drift = 10**offset / (S + 10**offset)` where `S = sqrt(received0 * received1)`.
    ///         For ~ppm drift the offset SHOULD be 6-12 dB below `log10(S)`.
    ///
    ///         Subclasses MAY override per-vault — for example, a stablecoin-pair vault
    ///         (6-decimal tokens) might return `6` to keep drift below 1ppm at typical
    ///         operator bootstrap sizes, while keeping the default `12` for 18-decimal
    ///         pairs. The override SHOULD return a value bound to the bootstrap-time
    ///         pair (e.g., cached in the `Assets` struct or derived from
    ///         `IERC20Metadata.decimals()` lookups), so a single vault's offset is stable.
    /// @param vaultId The vault to look up the offset for. Default impl ignores it.
    function _decimalsOffset(VaultId vaultId) internal view virtual returns (uint8) {
        vaultId; // silence unused-parameter warning
        return 12;
    }

    /// @notice Minimum number of `BlockNumberish`-clock blocks that must elapse between a
    ///         depositor's last `_deposit` and any subsequent `_withdraw` on the same vault.
    /// @dev    Default: `0`, meaning NO lock -- the depositor may withdraw in the same block
    ///         as their deposit. This is a deliberate semantic: subclasses opt INTO a lock
    ///         (typically `1` to reproduce the legacy "same-block ban", or `N > 1` for a
    ///         longer hold) rather than the base imposing one. PoolVault overrides this to
    ///         read a per-pool storage value set at pool initialization.
    /// @param  vaultId The vault to look up the lock for. Default impl ignores it.
    /// @return blocks  Number of `BlockNumberish`-clock blocks the lock spans.
    function _minDepositBlocks(VaultId vaultId) internal view virtual returns (uint64) {
        vaultId; // silence unused-parameter warning
        return 0;
    }

    /// @notice Accounting checkpoint fired immediately BEFORE any share-balance mutation for
    ///         `user`, carrying the pre-mutation total and user share counts. A composed
    ///         capability (e.g. a liquidity-incentives `RewardsLib`) overrides this to settle
    ///         per-share accrual on the balances in force until now, following the Synthetix
    ///         `updateReward` pattern (settle the global index against the OLD supply, then the
    ///         user against their OLD balance, before the counts change). Fires on bootstrap,
    ///         deposit, and withdraw. Default no-op, so vaults without an incentive capability
    ///         are unaffected.
    /// @param vaultId           The vault whose shares are about to change.
    /// @param user              The account whose share balance is about to change.
    /// @param totalSharesBefore Total shares outstanding immediately before the mutation.
    /// @param userSharesBefore  `user`'s share balance immediately before the mutation.
    function _onShareCheckpoint(VaultId vaultId, address user, uint256 totalSharesBefore, uint256 userSharesBefore)
        internal
        virtual {}

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
