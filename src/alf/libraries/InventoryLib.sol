// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Inventory, CurrencyState} from "../types/Inventory.sol";

/// @title InventoryLib
/// @author Uniswap Labs
/// @notice The token-custody half of the `Inventory` capability: the operations that move tokens
///         and therefore need the consuming contract's execution context. Internal library
///         functions inline into the consumer, so `address(this)` (the token custodian), vault
///         `deposit`/`withdraw`/`redeem`, PoolManager `take`/`burn`, and allowance checks all
///         resolve against the consumer. The pure, context-free `Inventory` operations
///         (accessors, balance views, claim accounting) are file-level free functions in
///         `types/Inventory.sol`; a consumer binds this library with `using InventoryLib for
///         Inventory` so both halves are invoked uniformly as `_inventory.method(...)`.
/// @dev The vault-fee guards' errors ({VaultChargesEntryFee}/{VaultChargesExitFee}) live here so
///      callers that match on them keep a stable qualified reference.
/// @custom:security-contact security@uniswap.org
library InventoryLib {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev A vault redemption returned more shares than the bucket owns. Defensive; should
    ///      never trigger if `vaultShares` accounting is consistent.
    error CrossPoolShareLeak();
    /// @dev `vault.deposit` returned zero shares for a non-zero asset deposit. Reverting fail-fast
    ///      prevents asset loss into a vault that gives no claim back.
    error ZeroSharesMinted();
    /// @dev The configured ERC-4626 vault applies an entry fee (`previewDeposit < convertToShares`).
    error VaultChargesEntryFee();
    /// @dev The configured ERC-4626 vault applies an exit fee (`previewRedeem < convertToAssets`).
    error VaultChargesExitFee();

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
    /// @dev No-ops (no vault / zero raw) return `ok = true`. The vault-deposit failure is caught; a
    ///      successful-but-zero-share deposit still reverts {ZeroSharesMinted}. When `ok` is false
    ///      and `amount > 0` the consumer SHOULD emit its own deposit-skipped event with `reason`.
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
    /// @dev `shares == 0` means nothing to drain (the consumer emits no event); otherwise `ok` true
    ///      ⇒ consumer emits drained(shares, assets), false ⇒ consumer emits
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
    /// @dev On the vaulted-shortfall path the bucket is set to `0` rather than computed: it
    ///      withdraws exactly `shortfall = amount - bal`, so after crediting the withdrawal and
    ///      debiting `amount` the bucket nets to zero (`bal + shortfall == amount`). Do not
    ///      "fix" this into an arithmetic expression; the literal zero is the correct result.
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

    /// @notice Redeem the bucket's ERC-6909 claims to raw ERC-20 via `pm` (only inside an unlock).
    /// @dev Caps the physical `take` at the PoolManager's current balance, since claims minted by
    ///      an earlier same-bucket swap in the same unsettled tx are not yet backed, and retains
    ///      any unbacked remainder as claims.
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

    /// @notice Zero the consumer's standing approval to `vault`. The emergency counterpart to
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
