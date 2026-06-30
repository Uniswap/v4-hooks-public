// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Inventory, InsufficientPoolBalance} from "../../src/alf/types/Inventory.sol";
import {InventoryLib} from "../../src/alf/libraries/InventoryLib.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockMorphoVaultV2} from "./mocks/MockMorphoVaultV2.sol";

/// @notice Harness holding a real `Inventory` storage value and exposing both halves of the
///         capability as external calls. The context-free free functions (accessors, balance
///         views, claim accounting) and the context-bound `InventoryLib` operations (vault
///         deposit/withdraw/redeem, allowance management) are both invoked uniformly as
///         `_inv.method(...)`. The `InventoryLib` functions inline into this harness, so
///         `address(this)` (the token custodian and vault depositor) resolves to the harness:
///         that is exactly why they live in the library and why isolated coverage of them is
///         possible without standing up a full hook.
contract InventoryHarness {
    using InventoryLib for Inventory;

    Inventory internal _inv;

    /// @dev Mirror of `PoolVault._bucket`: `keccak256(abi.encode(poolId, currency))` derived in
    ///      the scratch region. The harness keys directly on `(bytes32 poolId, Currency currency)`
    ///      so callers compose arbitrary buckets without a PoolKey.
    function bucketOf(bytes32 poolId, Currency currency) public pure returns (bytes32 bucket) {
        assembly ("memory-safe") {
            mstore(0x00, poolId)
            mstore(0x20, currency)
            bucket := keccak256(0x00, 0x40)
        }
    }

    // ─── Free-function accessors / views ──────────────────────────────────────────────────────

    function vaultOf(bytes32 bucket) external view returns (IERC4626) {
        return _inv.vaultOf(bucket);
    }

    function setVault(bytes32 bucket, IERC4626 vault) external {
        _inv.setVault(bucket, vault);
    }

    function sharesOf(bytes32 bucket) external view returns (uint256) {
        return _inv.sharesOf(bucket);
    }

    function erc20Of(bytes32 bucket) external view returns (uint256) {
        return _inv.erc20Of(bucket);
    }

    function claimsOf(bytes32 bucket) external view returns (uint256) {
        return _inv.claimsOf(bucket);
    }

    function assetBalance(bytes32 bucket) external view returns (uint256) {
        return _inv.assetBalance(bucket);
    }

    function effectiveBalance(bytes32 bucket) external view returns (uint256) {
        return _inv.effectiveBalance(bucket);
    }

    function unbackedClaims(bytes32 bucket, Currency currency, IPoolManager pm) external view returns (uint256) {
        return _inv.unbackedClaims(bucket, currency, pm);
    }

    function recordClaims(bytes32 bucket, uint256 amount) external {
        _inv.recordClaims(bucket, amount);
    }

    function debitERC20(bytes32 bucket, uint256 amount) external {
        _inv.debitERC20(bucket, amount);
    }

    // ─── InventoryLib context-bound ops ─────────────────────────────────────────────────────────

    function depositToVault(bytes32 bucket, Currency currency, uint256 amount) external {
        _inv.depositToVault(bucket, currency, amount);
    }

    function withdrawFromVault(bytes32 bucket, uint256 amount) external {
        _inv.withdrawFromVault(bucket, amount);
    }

    function ensureERC20(bytes32 bucket, uint256 amount) external {
        _inv.ensureERC20(bucket, amount);
    }

    function tryDepositAll(bytes32 bucket) external returns (uint256 amount, bool ok, bytes memory reason) {
        return _inv.tryDepositAll(bucket);
    }

    function tryDrain(bytes32 bucket) external returns (uint256 shares, uint256 assets, bool ok, bytes memory reason) {
        return _inv.tryDrain(bucket);
    }

    function requireFeelessVault(IERC4626 vault) external view {
        InventoryLib.requireFeelessVault(vault);
    }

    function approveVault(Currency currency, address vault) external {
        InventoryLib.approveVault(currency, vault);
    }

    /// @dev Seed the bucket's raw ERC-20 counter without going through a vault. Mirrors the
    ///      no-vault `depositToVault` credit path so tests can stage a raw balance directly.
    function creditERC20(bytes32 bucket, Currency currency, uint256 amount) external {
        _inv.depositToVault(bucket, currency, amount);
    }
}

/// @title InventoryTest
/// @notice Isolated unit tests for the `Inventory` capability type and `InventoryLib`, targeting
///         the revert / event / view branches a full PoolVault integration test does not exercise
///         directly. The harness holds the storage value; `InventoryLib` ops run in its context.
contract InventoryTest is Test {
    InventoryHarness internal h;

    MockERC20 internal token;
    MockERC4626 internal vault;

    bytes32 internal bucket;
    Currency internal currency;

    /// @dev Local mirror of the `VaultBound` event declared at file scope in Inventory.sol. A local
    ///      declaration (rather than importing the symbol) gives `vm.expectEmit` a definition to
    ///      `emit` against; the topic/data layout is identical, which is what `expectEmit` matches.
    event VaultBound(bytes32 indexed bucket, IERC4626 vault);

    function setUp() public {
        h = new InventoryHarness();
        token = new MockERC20("Token", "TKN", 18);
        vault = new MockERC4626(ERC20(address(token)));
        currency = Currency.wrap(address(token));
        bucket = h.bucketOf(bytes32(uint256(0xABCD)), currency);
    }

    // ─── helpers ────────────────────────────────────────────────────────────────────────────────

    /// @dev Bind `vault` to `bucket` and grant it max allowance, mirroring the production
    ///      bind-time approval so deposits do not trip on allowance.
    function _bindVault(IERC4626 v) internal {
        h.setVault(bucket, v);
        h.approveVault(currency, address(v));
    }

    /// @dev Fund the harness with `amount` underlying so it can deposit into a vault.
    function _fundHarness(uint256 amount) internal {
        token.mint(address(h), amount);
    }

    /// @dev Leading 4-byte selector of captured revert data. A direct `bytes4(bytes memory)` cast
    ///      is not valid Solidity, so read the first word from the data region and truncate.
    function _selector(bytes memory data) internal pure returns (bytes4 sel) {
        require(data.length >= 4, "reason too short");
        assembly {
            sel := mload(add(data, 0x20))
        }
    }

    // ══════════════════════════════════════════════════════════
    //  debitERC20
    // ══════════════════════════════════════════════════════════

    function test_debitERC20_revertsWhenAmountExceedsBucketBalance() public {
        // Stage 100 raw ERC-20 in the bucket (no vault bound -> raw credit).
        _fundHarness(100);
        h.creditERC20(bucket, currency, 100);
        assertEq(h.erc20Of(bucket), 100, "raw ERC-20 staged");

        // Debiting one wei past the tracked balance reverts; the bucket's global balance is the
        // source of truth, not the contract's `balanceOf`.
        vm.expectRevert(InsufficientPoolBalance.selector);
        h.debitERC20(bucket, 101);
    }

    function test_debitERC20_revertsWhenBucketEmpty() public {
        // An untouched bucket has zero raw; any non-zero debit reverts.
        vm.expectRevert(InsufficientPoolBalance.selector);
        h.debitERC20(bucket, 1);
    }

    function test_debitERC20_succeedsUpToExactBalance() public {
        _fundHarness(100);
        h.creditERC20(bucket, currency, 100);

        h.debitERC20(bucket, 60);
        assertEq(h.erc20Of(bucket), 40, "partial debit");

        // Exact-balance debit drains to zero and must not revert.
        h.debitERC20(bucket, 40);
        assertEq(h.erc20Of(bucket), 0, "exact-balance debit drains bucket");
    }

    function test_debitERC20_zeroAmountIsNoop_evenOnEmptyBucket() public {
        // The `amount == 0` early-return runs before the balance check, so a zero debit on an
        // empty bucket must NOT revert.
        h.debitERC20(bucket, 0);
        assertEq(h.erc20Of(bucket), 0, "zero debit leaves bucket untouched");
    }

    function test_debitERC20_zeroAmount_leavesNonZeroBalanceUntouched() public {
        _fundHarness(50);
        h.creditERC20(bucket, currency, 50);

        h.debitERC20(bucket, 0);
        assertEq(h.erc20Of(bucket), 50, "zero debit is a true no-op");
    }

    // ══════════════════════════════════════════════════════════
    //  recordClaims
    // ══════════════════════════════════════════════════════════

    function test_recordClaims_accumulates() public {
        assertEq(h.claimsOf(bucket), 0, "fresh bucket has no claims");

        h.recordClaims(bucket, 100e18);
        assertEq(h.claimsOf(bucket), 100e18, "first record");

        h.recordClaims(bucket, 50e18);
        assertEq(h.claimsOf(bucket), 150e18, "second record accumulates");

        // A zero record is a harmless no-op (the cast of `x + 0` is well-defined).
        h.recordClaims(bucket, 0);
        assertEq(h.claimsOf(bucket), 150e18, "zero record is a no-op");
    }

    function test_recordClaims_atUint128Max() public {
        // The field is uint128; recording exactly the max must succeed and round-trip.
        h.recordClaims(bucket, type(uint128).max);
        assertEq(h.claimsOf(bucket), type(uint128).max, "exactly uint128 max fits");
    }

    function test_recordClaims_revertsOnUint128Overflow() public {
        // First record the max, then one more wei must trip the SafeCast.toUint128 guard:
        // (uint256(claims) + amount) > type(uint128).max.
        h.recordClaims(bucket, type(uint128).max);

        // SafeCast.toUint128 reverts with the library's SafeCastOverflow selector. Match the
        // revert without binding to the exact selector so the test stays robust to the SafeCast
        // implementation; the accumulation that triggers it is the load-bearing branch.
        vm.expectRevert();
        h.recordClaims(bucket, 1);
    }

    function test_recordClaims_overflowFromSplitAmounts() public {
        // Overflow on accumulation, not on a single oversized record: half the max plus more than
        // half overflows the uint128 sum.
        uint256 half = uint256(type(uint128).max) / 2 + 1;
        h.recordClaims(bucket, half);
        vm.expectRevert();
        h.recordClaims(bucket, half);
    }

    // ══════════════════════════════════════════════════════════
    //  unbackedClaims
    // ══════════════════════════════════════════════════════════

    /// @dev `unbackedClaims` reads ONLY `currency.balanceOf(address(pm))`, so the `pm` argument can
    ///      be any address holding the underlying. We use a labelled EOA cast to `IPoolManager` and
    ///      seed its ERC-20 balance to model the PoolManager's backing without standing up a real
    ///      PoolManager (the burn/take redemption path in `redeemClaims` is exercised by the
    ///      PoolVault integration suite, which has a live manager inside an unlock).
    function _pm() internal returns (IPoolManager) {
        return IPoolManager(makeAddr("poolManagerStub"));
    }

    function test_unbackedClaims_zeroWhenNoClaims() public {
        IPoolManager pm = _pm();
        // No claims recorded -> early return 0, regardless of PM balance.
        assertEq(h.unbackedClaims(bucket, currency, pm), 0, "no claims -> nothing unbacked");
    }

    function test_unbackedClaims_zeroWhenFullyBacked() public {
        IPoolManager pm = _pm();
        h.recordClaims(bucket, 100e18);
        // PM holds exactly the claimed amount: fully backed.
        token.mint(address(pm), 100e18);
        assertEq(h.unbackedClaims(bucket, currency, pm), 0, "claims == backing -> fully backed");
    }

    function test_unbackedClaims_zeroWhenOverBacked() public {
        IPoolManager pm = _pm();
        h.recordClaims(bucket, 100e18);
        // PM holds more than the claims (e.g. other buckets' backing): still zero unbacked.
        token.mint(address(pm), 250e18);
        assertEq(h.unbackedClaims(bucket, currency, pm), 0, "backing > claims -> fully backed");
    }

    function test_unbackedClaims_nonZeroWhenPartiallyBacked() public {
        IPoolManager pm = _pm();
        h.recordClaims(bucket, 100e18);
        // PM holds only 40 of the 100 claimed: 60 is unbacked (settle still pending).
        token.mint(address(pm), 40e18);
        assertEq(h.unbackedClaims(bucket, currency, pm), 60e18, "claims - available is unbacked");
    }

    function test_unbackedClaims_fullyUnbackedWhenPMEmpty() public {
        IPoolManager pm = _pm();
        h.recordClaims(bucket, 100e18);
        // PM holds nothing: the entire claim is unbacked.
        assertEq(h.unbackedClaims(bucket, currency, pm), 100e18, "no backing -> all claims unbacked");
    }

    // ══════════════════════════════════════════════════════════
    //  setVault event
    // ══════════════════════════════════════════════════════════

    function test_setVault_emitsVaultBound() public {
        vm.expectEmit(true, false, false, true, address(h));
        emit VaultBound(bucket, IERC4626(address(vault)));
        h.setVault(bucket, IERC4626(address(vault)));

        assertEq(address(h.vaultOf(bucket)), address(vault), "vault bound");
    }

    function test_setVault_emitsVaultBound_onUnbindToZero() public {
        h.setVault(bucket, IERC4626(address(vault)));

        // Unbinding back to raw ERC-20 binds address(0) and still emits.
        vm.expectEmit(true, false, false, true, address(h));
        emit VaultBound(bucket, IERC4626(address(0)));
        h.setVault(bucket, IERC4626(address(0)));

        assertEq(address(h.vaultOf(bucket)), address(0), "unbound to raw ERC-20");
    }

    // ══════════════════════════════════════════════════════════
    //  assetBalance vs effectiveBalance
    // ══════════════════════════════════════════════════════════

    function test_balances_agree_withoutVault() public {
        // Raw + claims only; both views read the same fields, no vault leg.
        _fundHarness(300);
        h.creditERC20(bucket, currency, 300);
        h.recordClaims(bucket, 200);

        assertEq(h.assetBalance(bucket), 500, "raw + claims");
        assertEq(h.effectiveBalance(bucket), 500, "raw + claims (effective)");
    }

    function test_balances_agree_feelessVault() public {
        // A plain 1:1 MockERC4626 has no exit fee: convertToAssets == previewRedeem, so the two
        // views agree exactly.
        _bindVault(IERC4626(address(vault)));
        _fundHarness(1_000e18);
        h.depositToVault(bucket, currency, 1_000e18);

        uint256 asset = h.assetBalance(bucket);
        uint256 effective = h.effectiveBalance(bucket);
        assertEq(asset, 1_000e18, "assetBalance via convertToAssets");
        assertEq(effective, asset, "no exit fee -> views agree");
    }

    function test_balances_diverge_underExitFee() public {
        // VaultV2-shaped vault: convertToAssets is unchanged by the exit fee, previewRedeem shrinks.
        // assetBalance (convertToAssets, LP economic stake) MUST stay above effectiveBalance
        // (previewRedeem, realizable-now) by exactly the fee delta.
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        _bindVault(IERC4626(address(vv2)));
        _fundHarness(1_000e18);
        h.depositToVault(bucket, currency, 1_000e18);

        // Before any fee the two views agree.
        assertEq(h.assetBalance(bucket), h.effectiveBalance(bucket), "agree before fee");

        // Apply a 5% exit fee.
        vv2.setExitFeeBps(500);

        uint256 asset = h.assetBalance(bucket);
        uint256 effective = h.effectiveBalance(bucket);
        assertEq(asset, 1_000e18, "assetBalance ignores exit fee (convertToAssets)");
        assertEq(effective, 950e18, "effectiveBalance reflects 5% exit fee (previewRedeem)");
        assertLt(effective, asset, "effective < gross under exit fee");
    }

    function test_balances_includeRawAndClaims_alongsideVaultLeg() public {
        // Cover the claims + vault-leg addition for both views. Once a vault is bound,
        // `depositToVault` routes everything into shares, so the non-vault leg here is supplied by
        // recorded claims. With a feeless vault the convertToAssets/previewRedeem legs are equal.
        _bindVault(IERC4626(address(vault)));
        _fundHarness(700e18);
        h.depositToVault(bucket, currency, 700e18);
        h.recordClaims(bucket, 300e18);

        // assetBalance = claims(300) + convertToAssets(shares for 700) = 1000.
        assertEq(h.assetBalance(bucket), 1_000e18, "claims + vault leg");
        assertEq(h.effectiveBalance(bucket), 1_000e18, "claims + vault leg (effective, no fee)");
    }

    function test_assetBalance_zeroShares_skipsVaultLeg() public {
        // Vault bound but no shares: the `shares > 0` guard skips the vault call, leaving raw+claims.
        _bindVault(IERC4626(address(vault)));
        h.recordClaims(bucket, 42e18);
        assertEq(h.assetBalance(bucket), 42e18, "no shares -> claims only");
        assertEq(h.effectiveBalance(bucket), 42e18, "no shares -> claims only (effective)");
    }

    // ══════════════════════════════════════════════════════════
    //  InventoryLib.tryDepositAll
    // ══════════════════════════════════════════════════════════

    function test_tryDepositAll_noVault_isNoopOk() public {
        // No vault bound -> (0, true, "").
        _fundHarness(500);
        h.creditERC20(bucket, currency, 500);
        (uint256 amount, bool ok, bytes memory reason) = h.tryDepositAll(bucket);
        assertEq(amount, 0, "no-vault no-op reports zero amount");
        assertTrue(ok, "no-vault no-op is ok");
        assertEq(reason.length, 0, "no reason on no-op");
        assertEq(h.erc20Of(bucket), 500, "raw untouched");
    }

    function test_tryDepositAll_zeroRaw_isNoopOk() public {
        // Vault bound but the bucket holds no raw -> (0, true, "").
        _bindVault(IERC4626(address(vault)));
        (uint256 amount, bool ok, bytes memory reason) = h.tryDepositAll(bucket);
        assertEq(amount, 0, "zero-raw no-op reports zero amount");
        assertTrue(ok, "zero-raw no-op is ok");
        assertEq(reason.length, 0, "no reason on no-op");
    }

    function test_tryDepositAll_success_sweepsRawIntoVault() public {
        // Bind a vault but stage raw ERC-20 directly (bypassing the vault) so tryDepositAll has a
        // raw balance to sweep. We do this by binding AFTER crediting raw.
        _fundHarness(1_000e18);
        h.creditERC20(bucket, currency, 1_000e18); // no vault yet -> raw credit
        _bindVault(IERC4626(address(vault)));

        (uint256 amount, bool ok, bytes memory reason) = h.tryDepositAll(bucket);
        assertEq(amount, 1_000e18, "swept the full raw balance");
        assertTrue(ok, "deposit succeeded");
        assertEq(reason.length, 0, "no reason on success");
        assertEq(h.erc20Of(bucket), 0, "raw zeroed after sweep");
        assertGt(h.sharesOf(bucket), 0, "shares credited");
    }

    function test_tryDepositAll_catchesRevertingVault() public {
        // VaultV2 armed to revert on deposit. tryDepositAll must catch and report ok=false with a
        // non-empty reason, leaving the raw balance intact for a later retry.
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        _fundHarness(1_000e18);
        h.creditERC20(bucket, currency, 1_000e18); // raw credit before binding
        _bindVault(IERC4626(address(vv2)));
        vv2.setDepositShortfall(true);

        (uint256 amount, bool ok, bytes memory reason) = h.tryDepositAll(bucket);
        assertEq(amount, 1_000e18, "attempted the full raw balance");
        assertFalse(ok, "vault revert -> ok false");
        assertGt(reason.length, 0, "revert reason captured");
        assertEq(
            _selector(reason), MockMorphoVaultV2.DepositShortfall.selector, "reason is the vault's revert selector"
        );
        assertEq(h.erc20Of(bucket), 1_000e18, "raw preserved on failed deposit");
        assertEq(h.sharesOf(bucket), 0, "no shares minted on failure");
    }

    // ══════════════════════════════════════════════════════════
    //  InventoryLib.tryDrain
    // ══════════════════════════════════════════════════════════

    function test_tryDrain_noVault_earlyReturnsNotOk() public {
        // No vault configured -> (0, 0, false, ""). Note: unlike tryDepositAll, the no-vault path
        // returns ok=false (there is nothing to drain and no vault to drain from).
        (uint256 shares, uint256 assets, bool ok, bytes memory reason) = h.tryDrain(bucket);
        assertEq(shares, 0, "no shares");
        assertEq(assets, 0, "no assets");
        assertFalse(ok, "no-vault drain is not ok");
        assertEq(reason.length, 0, "no reason");
    }

    function test_tryDrain_zeroShares_earlyReturnsNotOk() public {
        // Vault bound but no shares owned -> (0, 0, false, "").
        _bindVault(IERC4626(address(vault)));
        (uint256 shares, uint256 assets, bool ok, bytes memory reason) = h.tryDrain(bucket);
        assertEq(shares, 0, "no shares");
        assertEq(assets, 0, "no assets");
        assertFalse(ok, "zero-shares drain is not ok");
        assertEq(reason.length, 0, "no reason");
    }

    function test_tryDrain_success_redeemsToRaw() public {
        _bindVault(IERC4626(address(vault)));
        _fundHarness(1_000e18);
        h.depositToVault(bucket, currency, 1_000e18);
        uint256 sharesBefore = h.sharesOf(bucket);
        assertGt(sharesBefore, 0, "shares present pre-drain");

        (uint256 shares, uint256 assets, bool ok, bytes memory reason) = h.tryDrain(bucket);
        assertEq(shares, sharesBefore, "drained the bucket's own shares");
        assertEq(assets, 1_000e18, "redeemed assets at 1:1");
        assertTrue(ok, "redeem succeeded");
        assertEq(reason.length, 0, "no reason on success");
        assertEq(h.sharesOf(bucket), 0, "shares zeroed");
        assertEq(h.erc20Of(bucket), 1_000e18, "assets credited to raw");
    }

    function test_tryDrain_catchesRevertingVault() public {
        // Deposit into a healthy VaultV2 first, then arm the withdraw/redeem shortfall so the
        // redeem reverts; tryDrain must catch it and preserve the shares.
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        _bindVault(IERC4626(address(vv2)));
        _fundHarness(1_000e18);
        h.depositToVault(bucket, currency, 1_000e18);
        uint256 sharesBefore = h.sharesOf(bucket);

        vv2.setWithdrawShortfall(true); // redeem() reverts WithdrawShortfall

        (uint256 shares, uint256 assets, bool ok, bytes memory reason) = h.tryDrain(bucket);
        assertEq(shares, sharesBefore, "drain operated on the bucket's shares");
        assertEq(assets, 0, "no assets received on failure");
        assertFalse(ok, "vault revert -> ok false");
        assertGt(reason.length, 0, "revert reason captured");
        assertEq(
            _selector(reason), MockMorphoVaultV2.WithdrawShortfall.selector, "reason is the vault's revert selector"
        );
        assertEq(h.sharesOf(bucket), sharesBefore, "shares preserved on failed drain");
    }

    // ══════════════════════════════════════════════════════════
    //  InventoryLib.requireFeelessVault
    // ══════════════════════════════════════════════════════════

    function test_requireFeelessVault_passesForZeroVault() public view {
        // address(0) vault is a no-op (raw-ERC20 bucket).
        h.requireFeelessVault(IERC4626(address(0)));
    }

    function test_requireFeelessVault_passesForFeelessVault() public view {
        // Plain MockERC4626: previewDeposit == convertToShares and previewRedeem == convertToAssets.
        h.requireFeelessVault(IERC4626(address(vault)));
    }

    function test_requireFeelessVault_revertsOnEntryFee() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        vv2.setEntryFeeBps(100); // previewDeposit < convertToShares
        vm.expectRevert(InventoryLib.VaultChargesEntryFee.selector);
        h.requireFeelessVault(IERC4626(address(vv2)));
    }

    function test_requireFeelessVault_revertsOnExitFee() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        vv2.setExitFeeBps(100); // previewRedeem < convertToAssets, entry side clean
        vm.expectRevert(InventoryLib.VaultChargesExitFee.selector);
        h.requireFeelessVault(IERC4626(address(vv2)));
    }

    // ══════════════════════════════════════════════════════════
    //  InventoryLib.depositToVault / withdrawFromVault / ensureERC20 (supporting paths)
    // ══════════════════════════════════════════════════════════

    function test_depositToVault_noVault_creditsRaw() public {
        // No vault bound -> raw ERC-20 credit, no token movement required.
        h.depositToVault(bucket, currency, 250e18);
        assertEq(h.erc20Of(bucket), 250e18, "credited raw");
        assertEq(h.sharesOf(bucket), 0, "no shares");
    }

    function test_depositToVault_zeroAmount_isNoop() public {
        _bindVault(IERC4626(address(vault)));
        h.depositToVault(bucket, currency, 0);
        assertEq(h.sharesOf(bucket), 0, "zero deposit mints nothing");
        assertEq(h.erc20Of(bucket), 0, "zero deposit credits nothing");
    }

    function test_withdrawFromVault_noVault_isNoop() public {
        // No vault bound -> withdrawFromVault returns without touching state.
        _fundHarness(100e18);
        h.creditERC20(bucket, currency, 100e18);
        h.withdrawFromVault(bucket, 50e18);
        assertEq(h.erc20Of(bucket), 100e18, "raw untouched, no vault to withdraw from");
    }

    function test_withdrawFromVault_zeroAmount_isNoop() public {
        _bindVault(IERC4626(address(vault)));
        _fundHarness(100e18);
        h.depositToVault(bucket, currency, 100e18);
        uint256 sharesBefore = h.sharesOf(bucket);
        h.withdrawFromVault(bucket, 0);
        assertEq(h.sharesOf(bucket), sharesBefore, "zero withdraw is a no-op");
    }

    function test_withdrawFromVault_movesVaultedToRaw() public {
        _bindVault(IERC4626(address(vault)));
        _fundHarness(100e18);
        h.depositToVault(bucket, currency, 100e18);

        h.withdrawFromVault(bucket, 40e18);
        assertEq(h.erc20Of(bucket), 40e18, "withdrawn amount credited to raw");
        assertGt(h.sharesOf(bucket), 0, "shares remain for the unwithdrawn portion");
    }

    function test_ensureERC20_sufficientRaw_debitsWithoutVault() public {
        // bal >= amount path: debit straight from raw.
        _fundHarness(100e18);
        h.creditERC20(bucket, currency, 100e18);
        h.ensureERC20(bucket, 60e18);
        assertEq(h.erc20Of(bucket), 40e18, "raw debited, no vault touched");
    }

    function test_ensureERC20_zeroAmount_isNoop() public {
        _fundHarness(10e18);
        h.creditERC20(bucket, currency, 10e18);
        h.ensureERC20(bucket, 0);
        assertEq(h.erc20Of(bucket), 10e18, "zero ensure is a no-op");
    }

    function test_ensureERC20_vaultedShortfall_withdrawsAndNetsToZero() public {
        // No raw, fully vaulted: ensuring `amount` withdraws exactly `amount` (bal == 0) and the
        // bucket nets to zero (the documented literal-zero result).
        _bindVault(IERC4626(address(vault)));
        _fundHarness(100e18);
        h.depositToVault(bucket, currency, 100e18);
        assertEq(h.erc20Of(bucket), 0, "all vaulted, no raw");

        h.ensureERC20(bucket, 30e18);
        assertEq(h.erc20Of(bucket), 0, "bucket nets to zero: withdrew exactly the shortfall, then debited it");
        assertGt(h.sharesOf(bucket), 0, "remaining shares for the unspent 70");
    }
}
