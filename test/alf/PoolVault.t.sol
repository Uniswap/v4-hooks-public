// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolVault} from "../../src/alf/base/PoolVault.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @dev Concrete test harness that exposes PoolVault's internal functions as external calls.
contract MockPoolVault is PoolVault {
    using PoolIdLibrary for PoolKey;

    IPoolManager private _pm;

    constructor(IPoolManager pm) {
        _pm = pm;
    }

    function _poolManager() internal view override returns (IPoolManager) {
        return _pm;
    }

    // ── Expose internals for testing ──

    function deposit(PoolKey calldata key, address from, address to, uint256 shares)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        return _deposit(key, from, to, shares);
    }

    function withdraw(PoolKey calldata key, address from, address to, uint256 shares)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        return _withdraw(key, from, to, shares);
    }

    function depositToVault(PoolId poolId, Currency currency, uint256 amount) external {
        _depositToVault(poolId, currency, amount);
    }

    function withdrawAllFromVault(PoolId poolId, Currency currency) external {
        _withdrawAllFromVault(poolId, currency);
    }

    function withdrawAllFromVaults(PoolId poolId, PoolKey calldata key) external {
        _withdrawAllFromVaults(poolId, key);
    }

    function depositAllToVault(PoolId poolId, Currency currency) external {
        _depositAllToVault(poolId, currency);
    }

    function depositAllToVaults(PoolId poolId, PoolKey calldata key) external {
        _depositAllToVaults(poolId, key);
    }

    function ensureERC20(PoolId poolId, Currency currency, uint256 amount) external {
        _ensureERC20(poolId, currency, amount);
    }

    function recordClaims(PoolId poolId, Currency currency, uint256 amount) external {
        _recordClaims(poolId, currency, amount);
    }

    function clearERC20Tracking(PoolId poolId, Currency currency) external {
        _clearERC20Tracking(poolId, currency);
    }

    // ── Test helpers to configure vaults and read internal state ──

    function setVault(PoolId poolId, Currency currency, IERC4626 vault) external {
        vaults[poolId][currency] = vault;
    }

    function getVaultShares(PoolId poolId, Currency currency) external view returns (uint256) {
        return _vaultShares[poolId][currency];
    }

    function getClaims(PoolId poolId, Currency currency) external view returns (uint256) {
        return _claims[poolId][currency];
    }

    function getERC20(PoolId poolId, Currency currency) external view returns (uint256) {
        return _erc20[poolId][currency];
    }
}

contract PoolVaultTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    MockPoolVault public vault;
    MockERC4626 public vault0;
    MockERC4626 public vault1;

    MockERC20 token0;
    MockERC20 token1;

    PoolKey poolKeyA;
    PoolId poolIdA;

    // A second pool with the same currencies for isolation tests
    PoolKey poolKeyB;
    PoolId poolIdB;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        // Deploy PoolManager (needed for _poolManager() but not for most tests)
        deployFreshManagerAndRouters();

        // Deploy tokens with deterministic ordering
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy mock ERC4626 vaults
        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        // Deploy test harness
        vault = new MockPoolVault(manager);

        // Construct two distinct pool keys (different tickSpacing to get different PoolIds)
        poolKeyA = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        poolIdA = poolKeyA.toId();

        poolKeyB = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolIdB = poolKeyB.toId();

        // Configure vaults for pool A
        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vault0)));
        vault.setVault(poolIdA, poolKeyA.currency1, IERC4626(address(vault1)));
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Mint tokens to `user`, approve `spender`, and deposit `shares` into poolKeyA.
    function _mintApproveDeposit(address user, uint256 shares) internal returns (uint256 a0, uint256 a1) {
        (uint256 need0, uint256 need1) = vault.previewDeposit(poolKeyA, shares);
        token0.mint(user, need0);
        token1.mint(user, need1);
        vm.startPrank(user);
        token0.approve(address(vault), need0);
        token1.approve(address(vault), need1);
        (a0, a1) = vault.deposit(poolKeyA, user, user, shares);
        vm.stopPrank();
    }

    /// @dev Same as _mintApproveDeposit but for an arbitrary pool key.
    function _mintApproveDepositPool(PoolKey memory key, address user, uint256 shares)
        internal
        returns (uint256 a0, uint256 a1)
    {
        (uint256 need0, uint256 need1) = vault.previewDeposit(key, shares);
        token0.mint(user, need0);
        token1.mint(user, need1);
        vm.startPrank(user);
        token0.approve(address(vault), need0);
        token1.approve(address(vault), need1);
        (a0, a1) = vault.deposit(key, user, user, shares);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  1. Share Math — First Deposit
    // ══════════════════════════════════════════════════════════

    function test_firstDeposit_oneShareEqualsOneUnit() public {
        (uint256 a0, uint256 a1) = _mintApproveDeposit(alice, 1000e18);

        assertEq(a0, 1000e18, "first deposit: amount0 should equal shares");
        assertEq(a1, 1000e18, "first deposit: amount1 should equal shares");
        assertEq(vault.totalShares(poolIdA), 1000e18);
        assertEq(vault.userShares(poolIdA, alice), 1000e18);
    }

    // ══════════════════════════════════════════════════════════
    //  2. Share Math — Subsequent Deposit Is Proportional
    // ══════════════════════════════════════════════════════════

    function test_subsequentDeposit_proportionalToExistingAssets() public {
        _mintApproveDeposit(alice, 1000e18);

        // Bob deposits the same number of shares — should require proportional tokens
        (uint256 a0, uint256 a1) = _mintApproveDeposit(bob, 1000e18);

        assertEq(a0, 1000e18);
        assertEq(a1, 1000e18);
        assertEq(vault.totalShares(poolIdA), 2000e18);
        assertEq(vault.userShares(poolIdA, bob), 1000e18);
    }

    // ══════════════════════════════════════════════════════════
    //  3. previewDeposit Rounds Up
    // ══════════════════════════════════════════════════════════

    function test_previewDeposit_roundsUp() public {
        // Deposit an amount that creates a non-trivial ratio
        _mintApproveDeposit(alice, 3e18);

        // Simulate yield to create a ratio where rounding matters
        // totalAssets0 = 3e18 + yield. For 1 share: amount = 1 * (3e18 + 1) / 3 => should round up
        vault0.simulateYield(1); // +1 wei of yield
        vault1.simulateYield(1);

        (uint256 previewUp0, uint256 previewUp1) = vault.previewDeposit(poolKeyA, 1e18);
        (uint256 previewDown0, uint256 previewDown1) = vault.previewWithdraw(poolKeyA, 1e18);

        // Deposit rounds up, withdraw rounds down. Deposit cost should be >= withdraw proceeds.
        assertGe(previewUp0, previewDown0, "previewDeposit should round up vs previewWithdraw");
        assertGe(previewUp1, previewDown1, "previewDeposit should round up vs previewWithdraw");
    }

    // ══════════════════════════════════════════════════════════
    //  4. previewWithdraw Rounds Down
    // ══════════════════════════════════════════════════════════

    function test_previewWithdraw_roundsDown() public {
        _mintApproveDeposit(alice, 3e18);

        // Simulate yield to create non-trivial ratio
        vault0.simulateYield(2);
        vault1.simulateYield(2);

        (uint256 amount0, uint256 amount1) = vault.previewWithdraw(poolKeyA, 1e18);

        // Manually compute expected: floor(1e18 * (3e18 + 2) / 3e18) = 1e18 + 0 = 1000000000000000000
        // 1e18 * (3e18 + 2) = 3e36 + 2e18
        // 3e36 + 2e18 / 3e18 = 1e18 + 2/3 => floor => 1e18
        assertEq(amount0, 1e18, "previewWithdraw should round down");
        assertEq(amount1, 1e18, "previewWithdraw should round down");
    }

    // ══════════════════════════════════════════════════════════
    //  5. totalAssets Reflects Vault + Claims + ERC20
    // ══════════════════════════════════════════════════════════

    function test_totalAssets_reflectsAllSources() public {
        _mintApproveDeposit(alice, 1000e18);

        // At this point, tokens are in the ERC4626 vaults
        (uint256 a0, uint256 a1) = vault.totalAssets(poolKeyA);
        assertEq(a0, 1000e18, "totalAssets should reflect vault deposits");
        assertEq(a1, 1000e18, "totalAssets should reflect vault deposits");

        // Add some claims
        vault.recordClaims(poolIdA, poolKeyA.currency0, 50e18);
        (a0, a1) = vault.totalAssets(poolKeyA);
        assertEq(a0, 1050e18, "totalAssets should include claims");
        assertEq(a1, 1000e18);

        // Simulate vault yield
        vault0.simulateYield(100e18);
        (a0,) = vault.totalAssets(poolKeyA);
        assertEq(a0, 1150e18, "totalAssets should include yield");
    }

    function test_totalAssets_includesERC20ForUnvaultedPool() public {
        // Pool B has no vaults configured — tokens tracked as ERC-20
        _mintApproveDepositPool(poolKeyB, alice, 500e18);

        (uint256 a0, uint256 a1) = vault.totalAssets(poolKeyB);
        assertEq(a0, 500e18, "totalAssets for unvaulted pool should reflect ERC-20 tracking");
        assertEq(a1, 500e18);
    }

    // ══════════════════════════════════════════════════════════
    //  6. Zero Shares Deposit/Withdraw Is a No-op
    // ══════════════════════════════════════════════════════════

    function test_zeroSharesDeposit_isNoop() public {
        _mintApproveDeposit(alice, 1000e18);

        uint256 sharesBefore = vault.totalShares(poolIdA);
        // Zero shares deposit: no tokens needed
        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.deposit(poolKeyA, alice, alice, 0);

        assertEq(a0, 0);
        assertEq(a1, 0);
        assertEq(vault.totalShares(poolIdA), sharesBefore);
    }

    function test_zeroSharesWithdraw_isNoop() public {
        _mintApproveDeposit(alice, 1000e18);

        uint256 sharesBefore = vault.userShares(poolIdA, alice);
        (uint256 a0, uint256 a1) = vault.withdraw(poolKeyA, alice, alice, 0);

        assertEq(a0, 0);
        assertEq(a1, 0);
        assertEq(vault.userShares(poolIdA, alice), sharesBefore);
    }

    // ══════════════════════════════════════════════════════════
    //  7. Deposit Pulls From `from`, Mints Shares to `to`
    // ══════════════════════════════════════════════════════════

    function test_deposit_pullsFromSenderMintsToRecipient() public {
        uint256 shares = 500e18;
        token0.mint(alice, shares);
        token1.mint(alice, shares);

        vm.startPrank(alice);
        token0.approve(address(vault), shares);
        token1.approve(address(vault), shares);
        vault.deposit(poolKeyA, alice, bob, shares);
        vm.stopPrank();

        // Alice's tokens were taken
        assertEq(token0.balanceOf(alice), 0, "tokens should be pulled from alice");
        assertEq(token1.balanceOf(alice), 0);

        // Bob received the shares
        assertEq(vault.userShares(poolIdA, bob), shares, "shares should be credited to bob");
        assertEq(vault.userShares(poolIdA, alice), 0, "alice should have no shares");
    }

    // ══════════════════════════════════════════════════════════
    //  8. Deposit Routes Tokens to Vault When Configured
    // ══════════════════════════════════════════════════════════

    function test_deposit_routesToVault() public {
        _mintApproveDeposit(alice, 1000e18);

        // Hook should hold no raw ERC-20 — all in vaults
        assertEq(token0.balanceOf(address(vault)), 0, "hook should hold no ERC-20 when vaulted");
        assertEq(token1.balanceOf(address(vault)), 0);

        // Vault should have the tokens
        assertGt(vault0.balanceOf(address(vault)), 0, "vault0 should hold shares");
        assertGt(vault1.balanceOf(address(vault)), 0, "vault1 should hold shares");

        // Internal vault share tracking should be non-zero
        assertGt(vault.getVaultShares(poolIdA, poolKeyA.currency0), 0);
        assertGt(vault.getVaultShares(poolIdA, poolKeyA.currency1), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  9. Deposit Tracks ERC-20 When No Vault Configured
    // ══════════════════════════════════════════════════════════

    function test_deposit_tracksERC20WhenNoVault() public {
        // Pool B has no vaults
        _mintApproveDepositPool(poolKeyB, alice, 1000e18);

        // ERC-20 tracking should match
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 1000e18);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency1), 1000e18);

        // Vault shares should be zero
        assertEq(vault.getVaultShares(poolIdB, poolKeyB.currency0), 0);
        assertEq(vault.getVaultShares(poolIdB, poolKeyB.currency1), 0);

        // Hook holds the raw ERC-20
        assertEq(token0.balanceOf(address(vault)), 1000e18);
        assertEq(token1.balanceOf(address(vault)), 1000e18);
    }

    // ══════════════════════════════════════════════════════════
    //  10. Withdraw Burns Shares, Sends Tokens to `to`
    // ══════════════════════════════════════════════════════════

    function test_withdraw_burnsSharesSendsTokens() public {
        _mintApproveDeposit(alice, 1000e18);

        uint256 bal0Before = token0.balanceOf(bob);
        uint256 bal1Before = token1.balanceOf(bob);

        // Alice withdraws, sends tokens to Bob
        (uint256 a0, uint256 a1) = vault.withdraw(poolKeyA, alice, bob, 500e18);

        assertEq(a0, 500e18);
        assertEq(a1, 500e18);
        assertEq(vault.userShares(poolIdA, alice), 500e18);
        assertEq(vault.totalShares(poolIdA), 500e18);
        assertEq(token0.balanceOf(bob) - bal0Before, 500e18, "bob should receive tokens");
        assertEq(token1.balanceOf(bob) - bal1Before, 500e18);
    }

    // ══════════════════════════════════════════════════════════
    //  11. Withdraw Pulls From Vault When ERC-20 Insufficient
    // ══════════════════════════════════════════════════════════

    function test_withdraw_pullsFromVaultOnShortfall() public {
        _mintApproveDeposit(alice, 1000e18);

        // Hook has 0 ERC-20 (all in vault). Withdrawal should redeem vault shares.
        assertEq(token0.balanceOf(address(vault)), 0);

        (uint256 a0,) = vault.withdraw(poolKeyA, alice, alice, 500e18);
        assertEq(a0, 500e18);

        // Vault shares should have decreased
        assertLt(
            vault.getVaultShares(poolIdA, poolKeyA.currency0),
            1000e18,
            "vault shares should decrease after withdrawal"
        );
    }

    // ══════════════════════════════════════════════════════════
    //  12. Withdraw Reverts With InsufficientShares
    // ══════════════════════════════════════════════════════════

    function test_withdraw_revertsInsufficientShares() public {
        _mintApproveDeposit(alice, 1000e18);

        vm.expectRevert(PoolVault.InsufficientShares.selector);
        vault.withdraw(poolKeyA, alice, alice, 1001e18);
    }

    function test_withdraw_revertsForUserWithNoShares() public {
        _mintApproveDeposit(alice, 1000e18);

        vm.expectRevert(PoolVault.InsufficientShares.selector);
        vault.withdraw(poolKeyA, bob, bob, 1);
    }

    // ══════════════════════════════════════════════════════════
    //  13. Multiple Users Deposit and Withdraw Proportionally
    // ══════════════════════════════════════════════════════════

    function test_multipleUsers_depositWithdrawProportionally() public {
        _mintApproveDeposit(alice, 1000e18);
        _mintApproveDeposit(bob, 1000e18);

        assertEq(vault.totalShares(poolIdA), 2000e18);
        assertEq(vault.userShares(poolIdA, alice), 1000e18);
        assertEq(vault.userShares(poolIdA, bob), 1000e18);

        // Alice withdraws half her shares
        vault.withdraw(poolKeyA, alice, alice, 500e18);
        assertEq(vault.userShares(poolIdA, alice), 500e18);
        assertEq(vault.totalShares(poolIdA), 1500e18);
        assertEq(token0.balanceOf(alice), 500e18);

        // Bob withdraws all his shares
        vault.withdraw(poolKeyA, bob, bob, 1000e18);
        assertEq(vault.userShares(poolIdA, bob), 0);
        assertEq(vault.totalShares(poolIdA), 500e18);
        assertEq(token0.balanceOf(bob), 1000e18);
    }

    // ══════════════════════════════════════════════════════════
    //  14. _depositToVault Records Vault Shares Correctly
    // ══════════════════════════════════════════════════════════

    function test_depositToVault_recordsVaultShares() public {
        uint256 amount = 500e18;
        token0.mint(address(vault), amount);

        vault.depositToVault(poolIdA, poolKeyA.currency0, amount);

        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), amount, "1:1 vault should track shares == amount");
        assertEq(token0.balanceOf(address(vault)), 0, "tokens should be in the ERC4626 vault");
    }

    function test_depositToVault_zeroAmountNoop() public {
        vault.depositToVault(poolIdA, poolKeyA.currency0, 0);
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), 0);
    }

    function test_depositToVault_noVaultTracksERC20() public {
        uint256 amount = 500e18;
        token0.mint(address(vault), amount);

        // Pool B has no vault configured
        vault.depositToVault(poolIdB, poolKeyB.currency0, amount);

        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), amount);
        assertEq(vault.getVaultShares(poolIdB, poolKeyB.currency0), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  15. _withdrawAllFromVault Caps at maxRedeem
    // ══════════════════════════════════════════════════════════

    function test_withdrawAllFromVault_redeemsCappedAtMax() public {
        _mintApproveDeposit(alice, 1000e18);

        uint256 sharesBefore = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        assertGt(sharesBefore, 0);

        vault.withdrawAllFromVault(poolIdA, poolKeyA.currency0);

        // Should have redeemed all (mock maxRedeem returns full balance)
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), 0, "all vault shares should be redeemed");
        assertEq(token0.balanceOf(address(vault)), 1000e18, "tokens should be back in hook");
    }

    function test_withdrawAllFromVault_noVaultNoop() public {
        // Pool B has no vault — should not revert
        vault.withdrawAllFromVault(poolIdB, poolKeyB.currency0);
    }

    function test_withdrawAllFromVault_zeroSharesNoop() public {
        // Pool A has a vault but no shares deposited
        vault.withdrawAllFromVault(poolIdA, poolKeyA.currency0);
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  16. _depositAllToVault Moves All ERC-20 Into Vault
    // ══════════════════════════════════════════════════════════

    function test_depositAllToVault_movesAllERC20() public {
        uint256 amount = 750e18;
        token0.mint(address(vault), amount);

        vault.depositAllToVault(poolIdA, poolKeyA.currency0);

        assertEq(token0.balanceOf(address(vault)), 0, "all ERC-20 should move into vault");
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), amount);
    }

    function test_depositAllToVault_noBalanceNoop() public {
        vault.depositAllToVault(poolIdA, poolKeyA.currency0);
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), 0);
    }

    function test_depositAllToVault_noVaultTracksERC20() public {
        uint256 amount = 300e18;
        token0.mint(address(vault), amount);

        vault.depositAllToVault(poolIdB, poolKeyB.currency0);

        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), amount);
    }

    // ══════════════════════════════════════════════════════════
    //  17. _ensureERC20 Pulls From Vault on Shortfall
    // ══════════════════════════════════════════════════════════

    function test_ensureERC20_pullsFromVaultOnShortfall() public {
        _mintApproveDeposit(alice, 1000e18);

        // Hook has 0 ERC-20 (all vaulted)
        assertEq(token0.balanceOf(address(vault)), 0);

        vault.ensureERC20(poolIdA, poolKeyA.currency0, 400e18);

        // Should have redeemed enough vault shares to cover 400e18
        assertGe(token0.balanceOf(address(vault)), 400e18, "should have at least the requested amount");
        assertLt(
            vault.getVaultShares(poolIdA, poolKeyA.currency0),
            1000e18,
            "vault shares should decrease"
        );
    }

    function test_ensureERC20_noopWhenSufficientBalance() public {
        _mintApproveDeposit(alice, 1000e18);

        // Manually put some ERC-20 in the hook
        token0.mint(address(vault), 500e18);

        uint256 vaultSharesBefore = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        vault.ensureERC20(poolIdA, poolKeyA.currency0, 500e18);

        // Should not touch vault shares since hook already has enough
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), vaultSharesBefore);
    }

    function test_ensureERC20_noVaultDebitsERC20Tracking() public {
        _mintApproveDepositPool(poolKeyB, alice, 1000e18);

        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 1000e18);

        vault.ensureERC20(poolIdB, poolKeyB.currency0, 300e18);

        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 700e18);
    }

    // ══════════════════════════════════════════════════════════
    //  18. _recordClaims Increments Per-Pool Claims
    // ══════════════════════════════════════════════════════════

    function test_recordClaims_incrementsClaims() public {
        vault.recordClaims(poolIdA, poolKeyA.currency0, 100e18);
        assertEq(vault.getClaims(poolIdA, poolKeyA.currency0), 100e18);

        vault.recordClaims(poolIdA, poolKeyA.currency0, 50e18);
        assertEq(vault.getClaims(poolIdA, poolKeyA.currency0), 150e18);
    }

    function test_recordClaims_perCurrencyIsolation() public {
        vault.recordClaims(poolIdA, poolKeyA.currency0, 100e18);
        vault.recordClaims(poolIdA, poolKeyA.currency1, 200e18);

        assertEq(vault.getClaims(poolIdA, poolKeyA.currency0), 100e18);
        assertEq(vault.getClaims(poolIdA, poolKeyA.currency1), 200e18);
    }

    // ══════════════════════════════════════════════════════════
    //  19. _redeemPoolClaims (Integration-Level)
    // ══════════════════════════════════════════════════════════
    //
    //  NOTE: _redeemPoolClaims calls _poolManager().burn() and
    //  _poolManager().take() which require a v4 unlock context.
    //  Testing this in isolation would require a full PM unlock
    //  callback pattern. These operations are covered by
    //  SmartPoolHook.t.sol integration tests. Skipped here to
    //  keep this suite focused on unit-level share math and
    //  vault operations.

    // ══════════════════════════════════════════════════════════
    //  20. _clearERC20Tracking Zeros the Balance
    // ══════════════════════════════════════════════════════════

    function test_clearERC20Tracking_zeros() public {
        _mintApproveDepositPool(poolKeyB, alice, 500e18);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 500e18);

        vault.clearERC20Tracking(poolIdB, poolKeyB.currency0);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 0);
    }

    function test_clearERC20Tracking_alreadyZeroNoop() public {
        vault.clearERC20Tracking(poolIdA, poolKeyA.currency0);
        assertEq(vault.getERC20(poolIdA, poolKeyA.currency0), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  21. Multi-Pool Isolation — Independent Shares
    // ══════════════════════════════════════════════════════════

    function test_multiPool_independentShares() public {
        // Configure vaults for pool B too
        vault.setVault(poolIdB, poolKeyB.currency0, IERC4626(address(vault0)));
        vault.setVault(poolIdB, poolKeyB.currency1, IERC4626(address(vault1)));

        _mintApproveDepositPool(poolKeyA, alice, 1000e18);
        _mintApproveDepositPool(poolKeyB, bob, 500e18);

        assertEq(vault.totalShares(poolIdA), 1000e18, "pool A shares");
        assertEq(vault.totalShares(poolIdB), 500e18, "pool B shares");
        assertEq(vault.userShares(poolIdA, alice), 1000e18);
        assertEq(vault.userShares(poolIdB, bob), 500e18);

        // Cross-check: alice has no shares in pool B
        assertEq(vault.userShares(poolIdB, alice), 0);
        assertEq(vault.userShares(poolIdA, bob), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  22. Multi-Pool Isolation — Independent Vault Share Tracking
    // ══════════════════════════════════════════════════════════

    function test_multiPool_independentVaultShareTracking() public {
        vault.setVault(poolIdB, poolKeyB.currency0, IERC4626(address(vault0)));
        vault.setVault(poolIdB, poolKeyB.currency1, IERC4626(address(vault1)));

        _mintApproveDepositPool(poolKeyA, alice, 1000e18);
        _mintApproveDepositPool(poolKeyB, bob, 500e18);

        uint256 poolAVaultShares = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        uint256 poolBVaultShares = vault.getVaultShares(poolIdB, poolKeyB.currency0);

        assertEq(poolAVaultShares, 1000e18, "pool A vault shares");
        assertEq(poolBVaultShares, 500e18, "pool B vault shares");
    }

    // ══════════════════════════════════════════════════════════
    //  23. Multi-Pool Isolation — Claims Don't Cross-Pollinate
    // ══════════════════════════════════════════════════════════

    function test_multiPool_claimsDontAffectOtherPool() public {
        vault.recordClaims(poolIdA, poolKeyA.currency0, 200e18);

        assertEq(vault.getClaims(poolIdA, poolKeyA.currency0), 200e18);
        assertEq(vault.getClaims(poolIdB, poolKeyB.currency0), 0, "pool B claims should be unaffected");
    }

    // ══════════════════════════════════════════════════════════
    //  24. Multi-Pool Isolation — Deposit to A Doesn't Change B
    // ══════════════════════════════════════════════════════════

    function test_multiPool_depositToADoesntChangeBTotalAssets() public {
        vault.setVault(poolIdB, poolKeyB.currency0, IERC4626(address(vault0)));
        vault.setVault(poolIdB, poolKeyB.currency1, IERC4626(address(vault1)));

        _mintApproveDepositPool(poolKeyB, bob, 500e18);

        (uint256 b0Before, uint256 b1Before) = vault.totalAssets(poolKeyB);

        // Deposit to pool A
        _mintApproveDepositPool(poolKeyA, alice, 1000e18);

        (uint256 b0After, uint256 b1After) = vault.totalAssets(poolKeyB);

        assertEq(b0After, b0Before, "pool B totalAssets0 should not change");
        assertEq(b1After, b1Before, "pool B totalAssets1 should not change");
    }

    // ══════════════════════════════════════════════════════════
    //  25. Yield Accrual Increases totalAssets and Share Value
    // ══════════════════════════════════════════════════════════

    function test_yieldAccrual_increasesShareValue() public {
        _mintApproveDeposit(alice, 1000e18);

        (uint256 before0, uint256 before1) = vault.totalAssets(poolKeyA);
        assertEq(before0, 1000e18);
        assertEq(before1, 1000e18);

        vault0.simulateYield(200e18);
        vault1.simulateYield(100e18);

        (uint256 after0, uint256 after1) = vault.totalAssets(poolKeyA);
        assertEq(after0, 1200e18, "totalAssets0 should include yield");
        assertEq(after1, 1100e18, "totalAssets1 should include yield");

        // Full withdrawal should return more than deposited
        (uint256 w0, uint256 w1) = vault.previewWithdraw(poolKeyA, 1000e18);
        assertEq(w0, 1200e18);
        assertEq(w1, 1100e18);
    }

    // ══════════════════════════════════════════════════════════
    //  26. New Depositor After Yield Pays Proportionally More
    // ══════════════════════════════════════════════════════════

    function test_yieldAccrual_newDepositorPaysMore() public {
        _mintApproveDeposit(alice, 1000e18);

        // Simulate 100% yield on token0
        vault0.simulateYield(1000e18);
        vault1.simulateYield(1000e18);

        // Now totalAssets = (2000e18, 2000e18) for 1000 shares
        // Bob's 1000 shares should cost 2000e18 of each token (rounded up)
        (uint256 need0, uint256 need1) = vault.previewDeposit(poolKeyA, 1000e18);
        assertEq(need0, 2000e18, "new depositor should pay more after yield");
        assertEq(need1, 2000e18);

        // Actually deposit and verify
        (uint256 a0, uint256 a1) = _mintApproveDeposit(bob, 1000e18);
        assertEq(a0, 2000e18);
        assertEq(a1, 2000e18);

        // Verify total shares
        assertEq(vault.totalShares(poolIdA), 2000e18);

        // Each user owns half the total assets: 2000e18 each
        (uint256 pa0, uint256 pa1) = vault.previewWithdraw(poolKeyA, 1000e18);
        assertEq(pa0, 2000e18, "each user should have equal share of total assets");
        assertEq(pa1, 2000e18);
    }

    // ══════════════════════════════════════════════════════════
    //  Additional Edge Cases
    // ══════════════════════════════════════════════════════════

    function test_withdrawAllFromVaults_bothCurrencies() public {
        _mintApproveDeposit(alice, 1000e18);

        vault.withdrawAllFromVaults(poolIdA, poolKeyA);

        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), 0);
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency1), 0);
        assertEq(token0.balanceOf(address(vault)), 1000e18);
        assertEq(token1.balanceOf(address(vault)), 1000e18);
    }

    function test_depositAllToVaults_bothCurrencies() public {
        token0.mint(address(vault), 800e18);
        token1.mint(address(vault), 600e18);

        vault.depositAllToVaults(poolIdA, poolKeyA);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), 800e18);
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency1), 600e18);
    }

    function test_deposit_emitsEvent() public {
        uint256 shares = 1000e18;
        token0.mint(alice, shares);
        token1.mint(alice, shares);

        vm.startPrank(alice);
        token0.approve(address(vault), shares);
        token1.approve(address(vault), shares);

        vm.expectEmit(true, true, false, true);
        emit PoolVault.Deposit(poolIdA, alice, shares, shares, shares);
        vault.deposit(poolKeyA, alice, alice, shares);
        vm.stopPrank();
    }

    function test_withdraw_emitsEvent() public {
        _mintApproveDeposit(alice, 1000e18);

        vm.expectEmit(true, true, false, true);
        emit PoolVault.Withdraw(poolIdA, alice, 500e18, 500e18, 500e18);
        vault.withdraw(poolKeyA, alice, alice, 500e18);
    }

    function test_fullWithdraw_drainsAllShares() public {
        _mintApproveDeposit(alice, 1000e18);

        vault.withdraw(poolKeyA, alice, alice, 1000e18);

        assertEq(vault.totalShares(poolIdA), 0);
        assertEq(vault.userShares(poolIdA, alice), 0);
        assertEq(token0.balanceOf(alice), 1000e18);
        assertEq(token1.balanceOf(alice), 1000e18);
    }

    function test_deposit_roundTripPreservesValueAfterYield() public {
        _mintApproveDeposit(alice, 1000e18);

        // Accrue yield
        vault0.simulateYield(333e18);
        vault1.simulateYield(777e18);

        // Bob deposits — should pay the post-yield price
        (uint256 cost0, uint256 cost1) = _mintApproveDeposit(bob, 1000e18);

        // Bob's share value should roughly equal what he paid (minus rounding)
        (uint256 val0, uint256 val1) = vault.previewWithdraw(poolKeyA, 1000e18);

        // Withdraw value should be <= deposit cost (rounding favors the pool)
        assertLe(val0, cost0, "withdraw should be <= deposit (rounding protects pool)");
        assertLe(val1, cost1, "withdraw should be <= deposit (rounding protects pool)");

        // But should be very close (within 1 wei per share of rounding)
        assertGe(val0, cost0 - 1, "rounding loss should be at most 1 wei");
        assertGe(val1, cost1 - 1, "rounding loss should be at most 1 wei");
    }

    function test_ensureERC20_partialVaultRedemption() public {
        _mintApproveDeposit(alice, 1000e18);

        // Request only a small amount — should only redeem what's needed
        vault.ensureERC20(poolIdA, poolKeyA.currency0, 100e18);

        uint256 remaining = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        // Should still have ~900 vault shares (1000 - 100 in a 1:1 vault)
        assertApproxEqAbs(remaining, 900e18, 1, "should only redeem needed shares");
    }
}
