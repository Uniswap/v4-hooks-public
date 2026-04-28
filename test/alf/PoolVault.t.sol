// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

    function bootstrap(PoolKey calldata key, address from, address to, uint256 amount0, uint256 amount1)
        external
        returns (uint256 shares)
    {
        return _bootstrap(key, from, to, amount0, amount1);
    }

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

    function depositAllToVault(PoolId poolId, Currency currency) external {
        _depositAllToVault(poolId, currency);
    }

    function ensureERC20(PoolId poolId, Currency currency, uint256 amount) external {
        _ensureERC20(poolId, currency, amount);
    }

    function recordClaims(PoolId poolId, Currency currency, uint256 amount) external {
        _recordClaims(poolId, currency, amount);
    }

    function setVault(PoolId poolId, Currency currency, IERC4626 vault) external {
        vaults[poolId][currency] = vault;
        // Mirror production's init-time approval so hot-path deposits don't need a
        // runtime allowance read.
        _approveVault(currency, address(vault));
    }

    function getVaultShares(PoolId poolId, Currency currency) external view returns (uint256) {
        return _vaultShares[poolId][currency];
    }

    function getClaims(PoolId poolId, Currency currency) external view returns (uint256) {
        return _state[poolId][currency].claims;
    }

    function getERC20(PoolId poolId, Currency currency) external view returns (uint256) {
        return _state[poolId][currency].erc20;
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

    PoolKey poolKeyA; // vaulted
    PoolId poolIdA;

    PoolKey poolKeyB; // unvaulted (same currencies)
    PoolId poolIdB;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();

        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        vault = new MockPoolVault(manager);

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

        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vault0)));
        vault.setVault(poolIdA, poolKeyA.currency1, IERC4626(address(vault1)));
    }

    // ══════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════

    /// @dev Bootstrap pool A with `(amount, amount)` from `user`. Returns total shares.
    function _bootstrap(address user, uint256 amount) internal returns (uint256 shares) {
        token0.mint(user, amount);
        token1.mint(user, amount);
        vm.startPrank(user);
        token0.approve(address(vault), amount);
        token1.approve(address(vault), amount);
        shares = vault.bootstrap(poolKeyA, user, user, amount, amount);
        vm.stopPrank();
        vm.roll(block.number + 1); // skip same-block-withdraw guard for tests
    }

    function _bootstrapPool(PoolKey memory key, address user, uint256 amount) internal returns (uint256 shares) {
        token0.mint(user, amount);
        token1.mint(user, amount);
        vm.startPrank(user);
        token0.approve(address(vault), amount);
        token1.approve(address(vault), amount);
        shares = vault.bootstrap(key, user, user, amount, amount);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Mint, approve, and deposit `shares` worth into pool A as `user`.
    function _depositA(address user, uint256 shares) internal returns (uint256 a0, uint256 a1) {
        (uint256 need0, uint256 need1) = vault.previewDeposit(poolKeyA, shares);
        token0.mint(user, need0);
        token1.mint(user, need1);
        vm.startPrank(user);
        token0.approve(address(vault), need0);
        token1.approve(address(vault), need1);
        (a0, a1) = vault.deposit(poolKeyA, user, user, shares);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    // ══════════════════════════════════════════════════════════
    //  Bootstrap
    // ══════════════════════════════════════════════════════════

    function test_bootstrap_mintsSqrtSharesAndLocksDeadShares() public {
        uint256 shares = _bootstrap(alice, 1000e18);

        // sqrt(1000e18 * 1000e18) = 1000e18
        assertEq(shares, 1000e18, "shares = sqrt(a0 * a1)");
        assertEq(vault.totalShares(poolIdA), 1000e18);
        assertEq(vault.userShares(poolIdA, alice), 1000e18 - vault.MINIMUM_SHARES());
        assertEq(vault.userShares(poolIdA, address(0)), vault.MINIMUM_SHARES());
    }

    function test_bootstrap_revertsWhenAlreadyBootstrapped() public {
        _bootstrap(alice, 1000e18);

        token0.mint(bob, 1e18);
        token1.mint(bob, 1e18);
        vm.startPrank(bob);
        token0.approve(address(vault), 1e18);
        token1.approve(address(vault), 1e18);
        vm.expectRevert(PoolVault.PoolAlreadyBootstrapped.selector);
        vault.bootstrap(poolKeyA, bob, bob, 1e18, 1e18);
        vm.stopPrank();
    }

    function test_bootstrap_revertsOnZeroAmounts() public {
        token0.mint(alice, 100);
        token1.mint(alice, 100);
        vm.startPrank(alice);
        token0.approve(address(vault), 100);
        token1.approve(address(vault), 100);

        vm.expectRevert(PoolVault.InsufficientBootstrap.selector);
        vault.bootstrap(poolKeyA, alice, alice, 0, 100);

        vm.expectRevert(PoolVault.InsufficientBootstrap.selector);
        vault.bootstrap(poolKeyA, alice, alice, 100, 0);
        vm.stopPrank();
    }

    function test_bootstrap_revertsBelowMinimumShares() public {
        // sqrt(1 * 1) = 1, well below MINIMUM_SHARES (1000)
        token0.mint(alice, 1);
        token1.mint(alice, 1);
        vm.startPrank(alice);
        token0.approve(address(vault), 1);
        token1.approve(address(vault), 1);
        vm.expectRevert(PoolVault.InsufficientBootstrap.selector);
        vault.bootstrap(poolKeyA, alice, alice, 1, 1);
        vm.stopPrank();
    }

    function test_addLiquidity_revertsIfNotBootstrapped() public {
        vm.expectRevert(PoolVault.PoolNotBootstrapped.selector);
        vault.deposit(poolKeyA, alice, alice, 100e18);
    }

    function test_previewDeposit_revertsIfNotBootstrapped() public {
        vm.expectRevert(PoolVault.PoolNotBootstrapped.selector);
        vault.previewDeposit(poolKeyA, 100e18);
    }

    // ══════════════════════════════════════════════════════════
    //  Subsequent deposit (post-bootstrap)
    // ══════════════════════════════════════════════════════════

    function test_subsequentDeposit_proportional() public {
        _bootstrap(alice, 1000e18);

        (uint256 a0, uint256 a1) = _depositA(bob, 500e18);

        // After bootstrap: total0 = total1 = 1000e18, supply = 1000e18.
        // 500e18 shares costs ceil(500e18 * 1000e18 / 1000e18) = 500e18 of each.
        assertEq(a0, 500e18);
        assertEq(a1, 500e18);
        assertEq(vault.userShares(poolIdA, bob), 500e18);
        assertEq(vault.totalShares(poolIdA), 1500e18);
    }

    function test_previewDeposit_roundsUp() public {
        _bootstrap(alice, 3e18);

        // Yield creates a non-trivial ratio so rounding matters.
        vault0.simulateYield(1);
        vault1.simulateYield(1);

        (uint256 up0, uint256 up1) = vault.previewDeposit(poolKeyA, 1e18);
        (uint256 down0, uint256 down1) = vault.previewWithdraw(poolKeyA, 1e18);

        assertGe(up0, down0, "deposit rounds up vs withdraw");
        assertGe(up1, down1);
    }

    // ══════════════════════════════════════════════════════════
    //  Withdraw
    // ══════════════════════════════════════════════════════════

    function test_withdraw_burnsSharesSendsTokens() public {
        _bootstrap(alice, 1000e18);

        uint256 aliceShares = vault.userShares(poolIdA, alice);
        uint256 bal0Before = token0.balanceOf(bob);
        uint256 bal1Before = token1.balanceOf(bob);

        // Alice withdraws half, sends to Bob.
        (uint256 a0, uint256 a1) = vault.withdraw(poolKeyA, alice, bob, aliceShares / 2);

        // After dead-share dilution: aliceShares ≈ 1000e18 - 1000. Withdraw half.
        // Returned amount per currency = floor(burned * 1000e18 / 1000e18).
        assertEq(a0, aliceShares / 2);
        assertEq(a1, aliceShares / 2);
        assertEq(vault.userShares(poolIdA, alice), aliceShares - aliceShares / 2);
        assertEq(token0.balanceOf(bob) - bal0Before, aliceShares / 2);
        assertEq(token1.balanceOf(bob) - bal1Before, aliceShares / 2);
    }

    function test_withdraw_revertsInsufficientShares() public {
        _bootstrap(alice, 1000e18);
        uint256 aliceShares = vault.userShares(poolIdA, alice);

        vm.expectRevert(PoolVault.InsufficientShares.selector);
        vault.withdraw(poolKeyA, alice, alice, aliceShares + 1);
    }

    function test_withdraw_revertsInSameBlockAsDeposit() public {
        _bootstrap(alice, 1000e18);
        // Bob deposits subsequent shares, attempts withdraw same block.
        (uint256 need0, uint256 need1) = vault.previewDeposit(poolKeyA, 100e18);
        token0.mint(bob, need0);
        token1.mint(bob, need1);
        vm.startPrank(bob);
        token0.approve(address(vault), need0);
        token1.approve(address(vault), need1);
        vault.deposit(poolKeyA, bob, bob, 100e18);
        // No vm.roll — same block.
        vm.expectRevert(PoolVault.SameBlockWithdraw.selector);
        vault.withdraw(poolKeyA, bob, bob, 100e18);
        vm.stopPrank();
    }

    function test_withdraw_succeedsNextBlock() public {
        _bootstrap(alice, 1000e18);
        (uint256 need0, uint256 need1) = vault.previewDeposit(poolKeyA, 100e18);
        token0.mint(bob, need0);
        token1.mint(bob, need1);
        vm.startPrank(bob);
        token0.approve(address(vault), need0);
        token1.approve(address(vault), need1);
        vault.deposit(poolKeyA, bob, bob, 100e18);
        vm.stopPrank();
        vm.roll(block.number + 1);
        vault.withdraw(poolKeyA, bob, bob, 100e18);
    }

    // ══════════════════════════════════════════════════════════
    //  totalAssets
    // ══════════════════════════════════════════════════════════

    function test_totalAssets_includesAllSources() public {
        _bootstrap(alice, 1000e18);

        (uint256 a0, uint256 a1) = vault.totalAssets(poolKeyA);
        assertEq(a0, 1000e18);
        assertEq(a1, 1000e18);

        // Add claims (per-pool record)
        vault.recordClaims(poolIdA, poolKeyA.currency0, 50e18);
        (a0,) = vault.totalAssets(poolKeyA);
        assertEq(a0, 1050e18);

        // Vault yield
        vault0.simulateYield(100e18);
        (a0,) = vault.totalAssets(poolKeyA);
        assertEq(a0, 1150e18);
    }

    function test_totalAssets_unvaultedPool_usesERC20() public {
        _bootstrapPool(poolKeyB, alice, 500e18);

        (uint256 a0, uint256 a1) = vault.totalAssets(poolKeyB);
        assertEq(a0, 500e18);
        assertEq(a1, 500e18);
    }

    // ══════════════════════════════════════════════════════════
    //  CROSS-POOL ISOLATION
    // ══════════════════════════════════════════════════════════

    /// @notice Confirms a swap-cycle's `_depositAllToVault` on Pool A does not sweep Pool B's
    ///         unvaulted ERC-20.
    function test_depositAllToVault_doesNotSweepOtherPoolsERC20() public {
        // Pool B (unvaulted) holds 500 of token0
        _bootstrapPool(poolKeyB, bob, 500e18);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 500e18);
        assertEq(token0.balanceOf(address(vault)), 500e18);

        // Bootstrap pool A (vaulted) — its tokens go to vault0, not the hook ERC-20 balance.
        _bootstrap(alice, 1000e18);
        // Hook still holds Pool B's 500e18 of token0
        assertEq(token0.balanceOf(address(vault)), 500e18);

        // Trigger pool A's `_depositAllToVault` for currency0.
        // It reads `_erc20[A][token0] == 0` and is a no-op.
        uint256 aSharesBefore = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        vault.depositAllToVault(poolIdA, poolKeyA.currency0);
        uint256 aSharesAfter = vault.getVaultShares(poolIdA, poolKeyA.currency0);

        assertEq(aSharesAfter, aSharesBefore, "Pool A should not have swept Pool B's tokens");
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 500e18, "Pool B's ledger intact");
        assertEq(token0.balanceOf(address(vault)), 500e18, "Pool B's tokens still in hook");
    }

    /// @notice Confirms `_ensureERC20` does not short-circuit using another pool's ERC-20.
    function test_ensureERC20_doesNotConsumeOtherPoolsERC20() public {
        _bootstrap(alice, 1000e18); // vaulted, _erc20[A] = 0
        _bootstrapPool(poolKeyB, bob, 500e18); // unvaulted, _erc20[B] = 500

        // Pool A needs 100 — should redeem from vault A, not consume pool B's 500e18.
        // It sees `_erc20[A] == 0`, so it redeems 100 from vault A.
        uint256 aVaultSharesBefore = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        vault.ensureERC20(poolIdA, poolKeyA.currency0, 100e18);
        uint256 aVaultSharesAfter = vault.getVaultShares(poolIdA, poolKeyA.currency0);

        assertLt(aVaultSharesAfter, aVaultSharesBefore, "vault redemption MUST occur");
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 500e18, "Pool B unaffected");
    }

    function test_assetSolvency_acrossTwoPoolsSharingCurrency() public {
        _bootstrap(alice, 1000e18);
        _bootstrapPool(poolKeyB, bob, 500e18);

        // Each pool's totalAssets matches its own deposit, regardless of the global token balance.
        (uint256 a0, uint256 a1) = vault.totalAssets(poolKeyA);
        (uint256 b0, uint256 b1) = vault.totalAssets(poolKeyB);

        assertEq(a0, 1000e18, "Pool A asset0 = its own bootstrap");
        assertEq(a1, 1000e18);
        assertEq(b0, 500e18, "Pool B asset0 = its own bootstrap");
        assertEq(b1, 500e18);

        // Sum of per-pool asset claims for each currency does NOT exceed available backing.
        uint256 sum0 = a0 + b0;
        uint256 sum1 = a1 + b1;
        uint256 backing0 = token0.balanceOf(address(vault)) + vault0.convertToAssets(vault0.balanceOf(address(vault)));
        uint256 backing1 = token1.balanceOf(address(vault)) + vault1.convertToAssets(vault1.balanceOf(address(vault)));
        assertLe(sum0, backing0, "asset solvency, currency0");
        assertLe(sum1, backing1, "asset solvency, currency1");
    }

    // ══════════════════════════════════════════════════════════
    //  Vault routing
    // ══════════════════════════════════════════════════════════

    function test_deposit_routesToVault_whenConfigured() public {
        _bootstrap(alice, 1000e18);
        assertEq(token0.balanceOf(address(vault)), 0, "no raw ERC-20 when vaulted");
        assertGt(vault.getVaultShares(poolIdA, poolKeyA.currency0), 0);
    }

    function test_deposit_tracksERC20_whenNoVault() public {
        _bootstrapPool(poolKeyB, alice, 1000e18);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 1000e18);
        assertEq(vault.getVaultShares(poolIdB, poolKeyB.currency0), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Multi-pool independence
    // ══════════════════════════════════════════════════════════

    function test_multiPool_sharesIsolated() public {
        // Alice in pool A, Bob in pool B.
        _bootstrap(alice, 1000e18);
        _bootstrapPool(poolKeyB, bob, 500e18);

        assertEq(vault.totalShares(poolIdA), 1000e18);
        assertEq(vault.totalShares(poolIdB), 500e18);
        assertEq(vault.userShares(poolIdA, alice), 1000e18 - vault.MINIMUM_SHARES());
        assertEq(vault.userShares(poolIdB, bob), 500e18 - vault.MINIMUM_SHARES());
        assertEq(vault.userShares(poolIdA, bob), 0);
        assertEq(vault.userShares(poolIdB, alice), 0);
    }

    function test_recordClaims_perPoolIsolation() public {
        vault.recordClaims(poolIdA, poolKeyA.currency0, 100e18);
        vault.recordClaims(poolIdB, poolKeyB.currency0, 50e18);

        assertEq(vault.getClaims(poolIdA, poolKeyA.currency0), 100e18);
        assertEq(vault.getClaims(poolIdB, poolKeyB.currency0), 50e18);
    }
}
