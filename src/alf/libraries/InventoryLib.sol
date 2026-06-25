// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title InventoryLib
/// @author Uniswap Labs
/// @notice Reusable rehypothecation + claim-accounting capability for ALF hooks, extracted from
///         `PoolVault`. Tracks three asset sources per opaque `bytes32 bucket`:
///
///           1. **ERC-4626 vault shares** — assets rehypothecated into yield-bearing vaults
///              between swaps, isolated per bucket so deployments that share a vault contract
///              cannot consume each other's shares.
///           2. **ERC-6909 claims** — deferred-settlement credits minted on the PoolManager
///              when a positive hook delta cannot yet be `take`n; redeemed via {redeemClaims}.
///           3. **Raw ERC-20** — tokens held directly by the consuming contract, attributed per
///              bucket. Source of truth for ownership; the contract's global `balanceOf` is
///              never read for accounting decisions.
///
///         ## Bucket key
///
///         `bucket` is opaque and consumer-defined: it is the accounting partition, distinct
///         from the asset (`currency`). `PoolVault` uses `keccak256(poolId, currency)` so a
///         multi-pool hook isolates same-currency pools; a token-keyed consumer (e.g. a native
///         book) uses `bytes32(uint256(uint160(token)))`. Functions that move tokens take
///         `currency` separately because the bucket alone does not name the underlying asset.
///
///         ## Storage
///
///         State lives at a fixed ERC-7201 namespaced slot via {load}, so the layout is stable
///         and collision-free regardless of which contract composes this capability or in what
///         order it inherits other state. Internal library functions are inlined into the
///         consumer, so `address(this)` / token custody refer to the consuming contract.
///
///         ## Events
///
///         This library is event-free by design: the V4 vs token-keyed consumers emit their own
///         (differently-keyed) events. The two best-effort paths ({tryDepositAll}, {tryDrain})
///         return a status the consumer inspects to emit its own event.
///
///         ## Compatibility
///
///         Vault interaction is via the ERC-4626 interface only and deliberately avoids
///         `maxWithdraw` on hot paths (curated/gated vaults such as Morpho VaultV2 return `0`);
///         {effectiveBalance} sizes via `previewRedeem`. Fee-on-entry/exit vaults are rejected
///         by {requireFeelessVault}; fee-on-transfer / rebasing underlyings are unsupported.
/// @custom:security-contact security@uniswap.org
library InventoryLib {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Packed per-bucket ERC-20 + ERC-6909 claim balance.
    /// @dev Co-located in one 32-byte slot so the pair-aware paths read both with a single
    ///      SLOAD. `uint128` per field dwarfs any plausible per-bucket amount; writes SafeCast.
    /// @param erc20  Raw ERC-20 tokens (in the token's native decimals) attributed to the bucket.
    /// @param claims ERC-6909 claims on the PoolManager (token's native decimals) for the bucket.
    struct CurrencyState {
        uint128 erc20;
        uint128 claims;
    }

    /// @notice Capability storage: per-bucket vault binding, rehypothecated shares, and the
    ///         packed raw + claim balances.
    /// @param vault       The ERC-4626 vault bound to a bucket (`address(0)` = hold as raw ERC-20).
    /// @param vaultShares The number of vault shares the bucket owns.
    /// @param state       The bucket's packed raw ERC-20 + ERC-6909 claim balances.
    struct Inventory {
        mapping(bytes32 bucket => IERC4626 vault) vault;
        mapping(bytes32 bucket => uint256 shares) vaultShares;
        mapping(bytes32 bucket => CurrencyState) state;
    }

    /// @dev ERC-7201 namespaced storage slot.
    ///      `keccak256(abi.encode(uint256(keccak256("alf.capability.inventory")) - 1)) & ~0xff`.
    bytes32 private constant INVENTORY_SLOT = 0x400777bcd4b0a67bcb6f1adeecaa0d50e896490c46a04ee107a0b5dd67093900;

    /// @dev A vault redemption returned more shares than the bucket owns. Defensive — should
    ///      never trigger if `vaultShares` accounting is consistent.
    error CrossPoolShareLeak();
    /// @dev {debitERC20} was asked to pay more than the bucket's tracked ERC-20 balance.
    error InsufficientPoolBalance();
    /// @dev `vault.deposit` returned zero shares for a non-zero asset deposit. Reverting
    ///      fail-fast prevents asset loss into a vault that gives no claim back.
    error ZeroSharesMinted();
    /// @dev The configured ERC-4626 vault applies an entry fee (`previewDeposit < convertToShares`).
    error VaultChargesEntryFee();
    /// @dev The configured ERC-4626 vault applies an exit fee (`previewRedeem < convertToAssets`).
    error VaultChargesExitFee();

    /// @notice Access the capability's namespaced storage.
    /// @return s The `Inventory` storage struct at the capability's ERC-7201 slot.
    function load() internal pure returns (Inventory storage s) {
        assembly ("memory-safe") {
            s.slot := INVENTORY_SLOT
        }
    }

    // ─────────────────────────────────────── Bucket accessors ──────────────────────────────────────

    /// @notice The ERC-4626 vault bound to `bucket`, or `address(0)` if held as raw ERC-20.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to read.
    /// @return The vault bound to the bucket, or the zero vault if none.
    function vaultOf(Inventory storage self, bytes32 bucket) internal view returns (IERC4626) {
        return self.vault[bucket];
    }

    /// @notice Bind `vault` to `bucket`. Caller validates the vault matches the currency.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to configure.
    /// @param vault  The ERC-4626 vault to bind (`address(0)` to hold the currency as raw ERC-20).
    function setVault(Inventory storage self, bytes32 bucket, IERC4626 vault) internal {
        self.vault[bucket] = vault;
    }

    /// @notice ERC-4626 shares this bucket owns.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to read.
    /// @return The vault share count held for the bucket.
    function sharesOf(Inventory storage self, bytes32 bucket) internal view returns (uint256) {
        return self.vaultShares[bucket];
    }

    /// @notice Raw ERC-20 attributed to this bucket.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to read.
    /// @return The raw ERC-20 balance (token's native decimals) attributed to the bucket.
    function erc20Of(Inventory storage self, bytes32 bucket) internal view returns (uint256) {
        return self.state[bucket].erc20;
    }

    /// @notice ERC-6909 claims attributed to this bucket.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to read.
    /// @return The ERC-6909 claim balance (token's native decimals) attributed to the bucket.
    function claimsOf(Inventory storage self, bytes32 bucket) internal view returns (uint256) {
        return self.state[bucket].claims;
    }

    // ────────────────────────────────────────── Balances ───────────────────────────────────────────

    /// @notice Gross managed balance: raw + claims + `convertToAssets(shares)`.
    /// @dev The vault leg is the true per-share economic value, ignoring exit fees or temporary
    ///      throttles — used by LP share math so claims are over true economic stake. Contrast
    ///      {effectiveBalance}, which sizes the vault leg via `previewRedeem`.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to value.
    /// @return bal The gross managed balance (token's native decimals).
    function assetBalance(Inventory storage self, bytes32 bucket) internal view returns (uint256 bal) {
        CurrencyState storage s = self.state[bucket];
        bal = uint256(s.erc20) + uint256(s.claims);
        IERC4626 vault = self.vault[bucket];
        if (address(vault) != address(0)) {
            uint256 shares = self.vaultShares[bucket];
            if (shares > 0) bal += vault.convertToAssets(shares);
        }
    }

    /// @notice Net realizable balance: raw + claims + `previewRedeem(shares)`.
    /// @dev The vault leg is what the vault would deliver right now (post exit fee). Used for
    ///      JIT-deployment sizing and indicative quotes so the cycle never sizes against funds
    ///      it cannot source. Contrast {assetBalance}, which uses `convertToAssets`.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to value.
    /// @return bal The immediately-realizable balance (token's native decimals).
    function effectiveBalance(Inventory storage self, bytes32 bucket) internal view returns (uint256 bal) {
        CurrencyState storage s = self.state[bucket];
        bal = uint256(s.erc20) + uint256(s.claims);
        IERC4626 vault = self.vault[bucket];
        if (address(vault) != address(0)) {
            uint256 shares = self.vaultShares[bucket];
            if (shares > 0) bal += vault.previewRedeem(shares);
        }
    }

    // ─────────────────────────────────────── Vault operations ──────────────────────────────────────

    /// @notice Deposit `amount` of `currency` (already held by the consumer) into `bucket`'s
    ///         vault, or credit raw ERC-20 if no vault is bound.
    /// @dev LP-path semantics: a vault rejection bubbles up to the caller (no try/catch). Reverts
    ///      {ZeroSharesMinted} if a non-zero deposit mints no shares.
    /// @param self     Capability storage.
    /// @param bucket   The accounting partition to credit.
    /// @param currency The underlying asset being deposited.
    /// @param amount   The asset amount to deposit (token's native decimals).
    function depositToVault(Inventory storage self, bytes32 bucket, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = self.vault[bucket];
        if (address(vault) == address(0)) {
            CurrencyState storage s = self.state[bucket];
            s.erc20 = (uint256(s.erc20) + amount).toUint128();
            return;
        }

        ensureVaultAllowance(currency, address(vault), amount);
        uint256 sharesActual = vault.deposit(amount, address(this));

        if (sharesActual == 0) revert ZeroSharesMinted();
        self.vaultShares[bucket] += sharesActual;
    }

    /// @notice Best-effort deposit of the bucket's tracked raw ERC-20 into its vault.
    /// @dev No-ops (no vault / zero raw) return `ok = true`. The vault-deposit failure is caught;
    ///      a successful-but-zero-share deposit still reverts {ZeroSharesMinted} (matching
    ///      {depositToVault}). When `ok` is false and `amount > 0` the consumer SHOULD emit its
    ///      own deposit-skipped event with `reason`.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition whose raw balance to sweep.
    /// @return amount The raw amount the deposit attempted (token's native decimals).
    /// @return ok     True if the deposit succeeded or was a no-op; false if the vault reverted.
    /// @return reason The raw revert data from `vault.deposit` when `ok` is false; empty otherwise.
    function tryDepositAll(Inventory storage self, bytes32 bucket)
        internal
        returns (uint256 amount, bool ok, bytes memory reason)
    {
        IERC4626 vault = self.vault[bucket];
        if (address(vault) == address(0)) return (0, true, "");
        CurrencyState storage s = self.state[bucket];
        amount = s.erc20;
        if (amount == 0) return (0, true, "");

        try vault.deposit(amount, address(this)) returns (uint256 sharesActual) {
            if (sharesActual == 0) revert ZeroSharesMinted();
            s.erc20 = 0;
            self.vaultShares[bucket] += sharesActual;
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @notice Withdraw `amount` of the bucket's vaulted assets back to raw ERC-20, optimistically.
    /// @dev No-op if no vault is bound. A vault revert bubbles up to the caller.
    ///      {CrossPoolShareLeak} guards against a vault consuming more shares than the bucket owns.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to withdraw for.
    /// @param amount The asset amount to pull from the vault (token's native decimals).
    function withdrawFromVault(Inventory storage self, bytes32 bucket, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = self.vault[bucket];
        if (address(vault) == address(0)) return;

        uint256 sharesUsed = vault.withdraw(amount, address(this), address(this));
        uint256 poolShares = self.vaultShares[bucket];
        if (sharesUsed > poolShares) revert CrossPoolShareLeak();
        self.vaultShares[bucket] = poolShares - sharesUsed;
        CurrencyState storage s = self.state[bucket];
        s.erc20 = (uint256(s.erc20) + amount).toUint128();
    }

    /// @notice Best-effort full redemption of the bucket's vault position back to raw ERC-20.
    /// @dev `shares == 0` means nothing to drain (the consumer emits no event); otherwise `ok`
    ///      true ⇒ consumer emits drained(shares, assets), false ⇒ consumer emits
    ///      drain-skipped(shares, reason). Redeems exactly the bucket's own shares, preserving
    ///      cross-bucket isolation.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to drain.
    /// @return shares The vault shares the drain operated on (`0` if nothing to drain).
    /// @return assets The asset amount received and credited to raw ERC-20 on success.
    /// @return ok     True if the redeem succeeded; false if the vault reverted.
    /// @return reason The raw revert data from `vault.redeem` when `ok` is false; empty otherwise.
    function tryDrain(Inventory storage self, bytes32 bucket)
        internal
        returns (uint256 shares, uint256 assets, bool ok, bytes memory reason)
    {
        IERC4626 vault = self.vault[bucket];
        if (address(vault) == address(0)) return (0, 0, false, "");
        shares = self.vaultShares[bucket];
        if (shares == 0) return (0, 0, false, "");

        try vault.redeem(shares, address(this), address(this)) returns (uint256 a) {
            self.vaultShares[bucket] = 0;
            CurrencyState storage s = self.state[bucket];
            s.erc20 = (uint256(s.erc20) + a).toUint128();
            assets = a;
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @notice Ensure the bucket's raw ERC-20 holds at least `amount`, withdrawing the shortfall
    ///         from the vault, then debit it.
    /// @dev For a non-vaulted bucket with insufficient raw, the `bal - amount` subtraction panics
    ///      on underflow (no sentinel). {CrossPoolShareLeak} guards the vaulted path.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to debit.
    /// @param amount The asset amount to make available and debit (token's native decimals).
    function ensureERC20(Inventory storage self, bytes32 bucket, uint256 amount) internal {
        if (amount == 0) return;
        CurrencyState storage s = self.state[bucket];
        uint256 bal = s.erc20;
        if (bal >= amount) {
            s.erc20 = uint128(bal - amount);
            return;
        }

        IERC4626 vault = self.vault[bucket];
        if (address(vault) == address(0)) {
            s.erc20 = uint128(bal - amount);
            return;
        }

        uint256 shortfall = amount - bal;
        uint256 sharesUsed = vault.withdraw(shortfall, address(this), address(this));
        uint256 poolShares = self.vaultShares[bucket];
        if (sharesUsed > poolShares) revert CrossPoolShareLeak();
        self.vaultShares[bucket] = poolShares - sharesUsed;
        s.erc20 = 0;
    }

    // ─────────────────────────────────────────── Claims ────────────────────────────────────────────

    /// @notice Redeem the bucket's ERC-6909 claims to raw ERC-20 via `pm` (only inside an unlock).
    /// @dev Caps the physical `take` at the PoolManager's current balance — claims minted by an
    ///      earlier same-bucket swap in the same unsettled tx are not yet backed — and retains any
    ///      unbacked remainder as claims.
    /// @param self     Capability storage.
    /// @param bucket   The accounting partition whose claims to redeem.
    /// @param currency The underlying asset of the claims.
    /// @param pm       The v4 PoolManager to burn the ERC-6909 claims on and `take` from.
    /// @return erc20Bal The bucket's raw ERC-20 balance after redemption (token's native decimals).
    function redeemClaims(Inventory storage self, bytes32 bucket, Currency currency, IPoolManager pm)
        internal
        returns (uint256 erc20Bal)
    {
        CurrencyState memory snapshot = self.state[bucket];
        uint256 claimBal = snapshot.claims;
        erc20Bal = snapshot.erc20;
        if (claimBal > 0) {
            uint256 available = currency.balanceOf(address(pm));
            uint256 takeAmount = claimBal < available ? claimBal : available;
            if (takeAmount > 0) {
                pm.burn(address(this), currency.toId(), takeAmount);
                pm.take(currency, address(this), takeAmount);
                erc20Bal += takeAmount;
            }
            self.state[bucket] =
                CurrencyState({erc20: erc20Bal.toUint128(), claims: (claimBal - takeAmount).toUint128()});
        }
    }

    /// @notice The portion of the bucket's claims the PoolManager cannot physically honor yet.
    /// @dev Claims whose backing settle is still pending this tx. Returns 0 in the common,
    ///      fully-backed case.
    /// @param self     Capability storage.
    /// @param bucket   The accounting partition to inspect.
    /// @param currency The underlying asset of the claims.
    /// @param pm       The v4 PoolManager whose balance bounds the backed portion.
    /// @return The unbacked claim amount (token's native decimals).
    function unbackedClaims(Inventory storage self, bytes32 bucket, Currency currency, IPoolManager pm)
        internal
        view
        returns (uint256)
    {
        uint256 claims = self.state[bucket].claims;
        if (claims == 0) return 0;
        uint256 available = currency.balanceOf(address(pm));
        return claims > available ? claims - available : 0;
    }

    /// @notice Record newly-minted ERC-6909 claims for a bucket (after `pm.mint`).
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to credit.
    /// @param amount The claim amount minted (token's native decimals).
    function recordClaims(Inventory storage self, bytes32 bucket, uint256 amount) internal {
        CurrencyState storage s = self.state[bucket];
        s.claims = (uint256(s.claims) + amount).toUint128();
    }

    /// @notice Debit `amount` from the bucket's raw ERC-20 after a PM settlement.
    /// @dev The `_settle` itself is the consumer's responsibility; this only updates the
    ///      per-bucket counter. Reverts {InsufficientPoolBalance} if the bucket is short.
    /// @param self   Capability storage.
    /// @param bucket The accounting partition to debit.
    /// @param amount The raw amount settled away (token's native decimals).
    function debitERC20(Inventory storage self, bytes32 bucket, uint256 amount) internal {
        if (amount == 0) return;
        CurrencyState storage s = self.state[bucket];
        uint256 bal = s.erc20;
        if (bal < amount) revert InsufficientPoolBalance();
        s.erc20 = uint128(bal - amount);
    }

    // ───────────────────────────────────────── Allowances ──────────────────────────────────────────

    /// @notice Grant max allowance to `vault` for `currency` (idempotent).
    /// @dev `forceApprove` zeros first for USDT-style tokens. Consumers call once per
    ///      (currency, vault) at bind. No-op for `address(0)` vault.
    /// @param currency The underlying asset to approve.
    /// @param vault    The ERC-4626 vault to grant allowance to.
    function approveVault(Currency currency, address vault) internal {
        if (vault == address(0)) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), vault) == 0) {
            token.forceApprove(vault, type(uint256).max);
        }
    }

    /// @notice Zero the consumer's standing approval to `vault` — the emergency counterpart to
    ///         {approveVault}.
    /// @dev Caller MUST also stop deposits, or the LP path re-arms it via {ensureVaultAllowance}.
    ///      No-op for `address(0)` vault.
    /// @param currency The underlying asset whose approval to revoke.
    /// @param vault    The ERC-4626 vault to revoke allowance from.
    function revokeVaultApproval(Currency currency, address vault) internal {
        if (vault == address(0)) return;
        IERC20(Currency.unwrap(currency)).forceApprove(vault, 0);
    }

    /// @notice Refresh allowance to `>= amount` (recovery for USDT-style tokens whose max
    ///         allowance is decremented on transfer).
    /// @dev No-op for the common non-decrementing case.
    /// @param currency The underlying asset to approve.
    /// @param vault    The ERC-4626 vault to grant allowance to.
    /// @param amount   The minimum allowance required for the current operation (native decimals).
    function ensureVaultAllowance(Currency currency, address vault, uint256 amount) internal {
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), vault) < amount) {
            token.forceApprove(vault, type(uint256).max);
        }
    }

    /// @notice Reject ERC-4626 vaults that apply entry or exit fees.
    /// @dev Leverages the EIP-4626 rule that `convertTo*` MUST NOT factor fees while `preview*`
    ///      MUST. No-op for an unset vault. Catches honest fee disclosures only (see PoolVault
    ///      `Vault Compatibility` for the adversarial-vault socialization that remains). Reverts
    ///      {VaultChargesEntryFee} / {VaultChargesExitFee} on divergence.
    /// @param vault The ERC-4626 vault to probe.
    function requireFeelessVault(IERC4626 vault) internal view {
        if (address(vault) == address(0)) return;
        uint256 probe = 10 ** uint256(vault.decimals());
        if (vault.previewDeposit(probe) != vault.convertToShares(probe)) revert VaultChargesEntryFee();
        if (vault.previewRedeem(probe) != vault.convertToAssets(probe)) revert VaultChargesExitFee();
    }
}
