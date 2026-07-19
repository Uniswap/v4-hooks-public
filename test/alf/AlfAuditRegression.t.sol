// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {DualPoolIncentivizedHook} from "../../src/alf/DualPoolIncentivizedHook.sol";
import {LiquidityBucket, MAX_BUCKETS, computeAllocations} from "../../src/alf/types/Distribution.sol";
import {VaultNotBootstrapped, AssetsAlreadyBound} from "../../src/alf/types/Shares.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title AlfDualPoolRegressionTest
/// @notice Executable regressions for the DualPool findings in the ALF security review. Each test
///         pins the finding's behavior so a future fix flips the assertion deliberately, and any
///         unintended change is caught. Findings that describe current (unfixed) behavior are
///         asserted as-is with a note on the intended remediation.
contract AlfDualPoolRegressionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DualPoolHook hook;
    MockERC4626 vault0;
    MockERC4626 vault1;
    MockERC20 token0;
    MockERC20 token1;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    PoolId poolId;

    uint256 constant BOOTSTRAP = 1e22;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));
        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook));

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 1_000, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);

        token0.mint(owner, BOOTSTRAP);
        token1.mint(owner, BOOTSTRAP);
        vm.startPrank(owner);
        token0.approve(address(hook), BOOTSTRAP);
        token1.approve(address(hook), BOOTSTRAP);
        hook.bootstrap(key, BOOTSTRAP, BOOTSTRAP);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @notice L-01: burning the entire share supply permanently bricks the pool — no re-bootstrap
    ///         path exists. Documents current behavior; a fix (V2-style locked MINIMUM_LIQUIDITY)
    ///         would make the full burn impossible and flip these assertions.
    function test_L01_fullShareBurnBricksPool() public {
        uint256 all = hook.sharesOf(key, owner);
        assertGt(all, 0, "owner should hold the bootstrap supply");

        vm.prank(owner);
        hook.removeLiquidity(key, all, 0, 0, type(uint256).max);
        assertEq(hook.totalShares(poolId), 0, "supply fully burned");

        // (a) New deposits are impossible: the pool now reads as un-bootstrapped.
        (uint256 w0, uint256 w1) = (1e18, 1e18);
        token0.mint(alice, w0);
        token1.mint(alice, w1);
        vm.startPrank(alice);
        token0.approve(address(hook), w0);
        token1.approve(address(hook), w1);
        vm.expectRevert(VaultNotBootstrapped.selector);
        hook.addLiquidity(key, 1e18, type(uint256).max, type(uint256).max, type(uint256).max);
        vm.stopPrank();

        // (b) Re-bootstrap is impossible: the asset pair is already bound.
        token0.mint(owner, BOOTSTRAP);
        token1.mint(owner, BOOTSTRAP);
        vm.startPrank(owner);
        token0.approve(address(hook), BOOTSTRAP);
        token1.approve(address(hook), BOOTSTRAP);
        vm.expectRevert(AssetsAlreadyBound.selector);
        hook.bootstrap(key, BOOTSTRAP, BOOTSTRAP);
        vm.stopPrank();
    }

    /// @notice L-05: `emergencyRevokeVault` zeroes the vault allowance, but a subsequent owner
    ///         `addLiquidity` (not gated on liveness, and owner bypasses the deposit gate) silently
    ///         re-arms it via `ensureVaultAllowance`. Documents current behavior; the intended fix
    ///         is a revoked-latch that blocks re-arm until an explicit `refreshVaultApproval`.
    function test_L05_emergencyRevokeRearmedByOwnerDeposit() public {
        assertEq(token0.allowance(address(hook), address(vault0)), type(uint256).max, "init: max vault0 allowance");

        vm.prank(owner);
        hook.emergencyRevokeVault(key);
        assertEq(token0.allowance(address(hook), address(vault0)), 0, "revoked: allowance zeroed");

        // Owner deposits into the paused pool → re-arms the very allowance the emergency zeroed.
        (uint256 w0, uint256 w1) = hook.previewDeposit(key, 1e18);
        token0.mint(owner, w0);
        token1.mint(owner, w1);
        vm.startPrank(owner);
        token0.approve(address(hook), w0);
        token1.approve(address(hook), w1);
        hook.addLiquidity(key, 1e18, type(uint256).max, type(uint256).max, type(uint256).max);
        vm.stopPrank();

        assertEq(
            token0.allowance(address(hook), address(vault0)),
            type(uint256).max,
            "L-05: owner deposit silently re-armed the revoked vault allowance"
        );
    }

    /// @notice L-03: `computeAllocations` reverts (v4 `toUint128` overflow) for a narrow bucket at
    ///         extreme single-side balance, which would brick JIT deploys + quotes for the pool.
    ///         Verifies the boundary: fine at 1e33/side, reverts at 1e36/side.
    function test_L03_computeAllocationsOverflowBoundary() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -1, tickUpper: 1, weightBps: 10_000});
        uint160 sp = TickMath.getSqrtPriceAtTick(0);

        // Below the boundary: succeeds.
        this.computeAllocationsExternal(dist, sp, 1e33, 1e33);

        // At extreme TVL in a narrow bucket: liquidity exceeds uint128 → revert.
        vm.expectRevert();
        this.computeAllocationsExternal(dist, sp, 1e36, 1e36);
    }

    /// @dev External wrapper so `vm.expectRevert` observes the free function's revert across a call
    ///      boundary (it is otherwise inlined into the test frame).
    function computeAllocationsExternal(LiquidityBucket[] memory buckets, uint160 sp, uint256 b0, uint256 b1)
        external
        pure
        returns (uint128[MAX_BUCKETS] memory liqs, uint256 need0, uint256 need1)
    {
        return computeAllocations(buckets, sp, b0, b1);
    }
}

/// @title AlfIncentivizedRegressionTest
/// @notice Executable regression for review finding M-01: reward emissions are farmable by
///         transient capital because accrual is on instantaneous share balance with only a short
///         deposit lock. Demonstrates that a large depositor present for just the minimum hold
///         window captures the overwhelming majority of that window's emissions.
contract AlfIncentivizedRegressionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    DualPoolIncentivizedHook hook;
    MockERC4626 vault0;
    MockERC4626 vault1;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 reward;

    address owner = makeAddr("owner");
    address committedLP = makeAddr("committedLP");
    address sniper = makeAddr("sniper");

    PoolId poolId;

    uint256 constant DURATION = 1_000; // blocks
    uint256 constant REWARD = 1_000 ether; // → rate = 1 ether/block
    uint256 constant SEED = 1 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));
        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));
        reward = new MockERC20("Reward", "RWD", 18);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolIncentivizedHook(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags))
        );
        deployCodeTo(
            "DualPoolIncentivizedHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook)
        );

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 1_000, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        // minDepositBlocks = 1: the shortest non-zero lock — the operator "did something" but it is
        // trivially small relative to the DURATION-block reward period.
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 1
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);

        _bootstrap(committedLP, SEED); // a genuine, committed LP present the whole period
        vm.startPrank(owner);
        hook.setRewardToken(key, IERC20(address(reward)));
        hook.setRewardsDuration(key, DURATION);
        vm.stopPrank();
        _fund(REWARD);
    }

    function _bootstrap(address who, uint256 amount) internal {
        // committedLP bootstraps (bootstrap is owner-only; transfer ownership context is not needed
        // — bootstrap must be the owner, so the owner bootstraps to `who` via a normal seed here).
        token0.mint(owner, amount);
        token1.mint(owner, amount);
        vm.startPrank(owner);
        token0.approve(address(hook), amount);
        token1.approve(address(hook), amount);
        hook.bootstrap(key, amount, amount);
        vm.stopPrank();
        vm.roll(block.number + 1);
        // Move the bootstrap shares to the "committed LP" conceptually: here the owner *is* the
        // committed long-term holder. `who` is unused for share custody; kept for readability.
        who;
    }

    function _fund(uint256 amount) internal {
        reward.mint(owner, amount);
        vm.startPrank(owner);
        reward.approve(address(hook), amount);
        hook.notifyRewardAmount(key, amount);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 shares) internal {
        (uint256 n0, uint256 n1) = hook.previewDeposit(key, shares);
        token0.mint(who, n0);
        token1.mint(who, n1);
        vm.startPrank(who);
        token0.approve(address(hook), n0);
        token1.approve(address(hook), n1);
        hook.addLiquidity(key, shares, type(uint256).max, type(uint256).max, type(uint256).max);
        vm.stopPrank();
    }

    /// @notice M-01: a sniper who deposits a dominant share, holds only `minDepositBlocks`, then
    ///         claims and exits captures the overwhelming majority of the emissions during their
    ///         holding window — despite near-zero time commitment. Emissions the committed LP would
    ///         otherwise have earned are diverted. A time-weighted/vesting accrual (or a
    ///         `minDepositBlocks` sized to the period) would blunt this.
    function test_M01_transientCapitalFarmsRewards() public {
        // Let the committed LP accrue over the first half of the period.
        vm.roll(block.number + DURATION / 2);

        uint256 ownerShares = hook.sharesOf(key, owner);

        // Sniper deposits ~99x the existing supply → ~99% of shares.
        uint256 snipeShares = ownerShares * 99;
        vm.roll(block.number + 1);
        _deposit(sniper, snipeShares);

        uint256 startBlock = block.number;
        uint256 rate = REWARD / DURATION; // 1 ether/block

        // Hold only the minimum lock window, then measure + exit.
        uint256 hold = 2; // blocks (>= minDepositBlocks = 1)
        vm.roll(startBlock + hold);

        uint256 windowEmissions = rate * hold;
        uint256 sniperEarned = hook.earned(key, sniper);

        // The sniper captured the vast majority of the window's emissions with no real commitment.
        assertGt(sniperEarned * 100, windowEmissions * 90, "M-01: sniper captured <90% of window emissions");

        // And they can immediately realize it and leave: claim succeeds and pays what was accrued.
        vm.prank(sniper);
        uint256 paid = hook.claimRewards(key);
        assertEq(paid, sniperEarned, "sniper claims exactly the diverted emissions");

        uint256 sniperBal = hook.sharesOf(key, sniper);
        vm.prank(sniper);
        hook.removeLiquidity(key, sniperBal, 0, 0, type(uint256).max); // exit after minimum hold
    }
}

/// @title AlfRewardCustodyRegressionTest
/// @notice Regression for review finding L-02: reward-token custody was commingled across the pools
///         on a single hook, so the `RewardRateTooHigh` solvency guard and the "reward token never
///         aliases pool inventory" NatSpec did not hold hook-wide. Locks the fix — reward tokens are
///         disjoint from every pool currency in BOTH directions, and a reward token shared across
///         pools stays per-pool solvent via the `Reward.committed` reservation.
contract AlfRewardCustodyRegressionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    DualPoolIncentivizedHook hook;
    MockERC20 reward;

    // Pool A: currency0/currency1 from Deployers.
    MockERC20 a0;
    MockERC20 a1;
    MockERC4626 va0;
    MockERC4626 va1;
    PoolKey keyA;

    // Pool B: a second, disjoint currency pair on the same hook, sharing A's reward token.
    MockERC20 b0;
    MockERC20 b1;
    MockERC4626 vb0;
    MockERC4626 vb1;
    PoolKey keyB;

    address owner = makeAddr("owner");

    uint24 constant FEE = 1_000;
    int24 constant TS = 10;
    uint256 constant DURATION = 1_000; // → rate = REWARD/DURATION = 1 ether/block (no dust)
    uint256 constant REWARD = 1_000 ether;
    uint256 constant SEED = 1 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        a0 = MockERC20(Currency.unwrap(currency0));
        a1 = MockERC20(Currency.unwrap(currency1));
        va0 = new MockERC4626(ERC20(address(a0)));
        va1 = new MockERC4626(ERC20(address(a1)));

        (b0, b1) = _sorted(new MockERC20("B0", "B0", 18), new MockERC20("B1", "B1", 18));
        vb0 = new MockERC4626(ERC20(address(b0)));
        vb1 = new MockERC4626(ERC20(address(b1)));

        reward = new MockERC20("Reward", "RWD", 18);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolIncentivizedHook(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags))
        );
        deployCodeTo(
            "DualPoolIncentivizedHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook)
        );

        keyA = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TS, hooks: IHooks(address(hook))
        });
        keyB = PoolKey({
            currency0: Currency.wrap(address(b0)),
            currency1: Currency.wrap(address(b1)),
            fee: FEE,
            tickSpacing: TS,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(owner);
        hook.initializePool(keyA, _config(va0, va1));
        hook.initializePool(keyB, _config(vb0, vb1));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────── Helpers ───────────────────────────────────────────

    function _sorted(MockERC20 x, MockERC20 y) internal pure returns (MockERC20, MockERC20) {
        return address(x) < address(y) ? (x, y) : (y, x);
    }

    function _config(MockERC4626 v0, MockERC4626 v1) internal pure returns (DualPoolHook.PoolConfig memory) {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        return DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: IERC4626(address(v0)),
            vault1: IERC4626(address(v1)),
            minDepositBlocks: 0
        });
    }

    function _bootstrap(PoolKey memory k, MockERC20 t0, MockERC20 t1, uint256 amt) internal {
        t0.mint(owner, amt);
        t1.mint(owner, amt);
        vm.startPrank(owner);
        t0.approve(address(hook), amt);
        t1.approve(address(hook), amt);
        hook.bootstrap(k, amt, amt);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _configureAndFund(PoolKey memory k, uint256 amount) internal {
        vm.startPrank(owner);
        hook.setRewardToken(k, IERC20(address(reward)));
        hook.setRewardsDuration(k, DURATION);
        reward.mint(owner, amount);
        reward.approve(address(hook), amount);
        hook.notifyRewardAmount(k, amount);
        vm.stopPrank();
    }

    // ───────────────────────────────── L-02: custody disjointness ──────────────────────────────────

    /// @notice L-02 (forward): a reward token is rejected if it is ANY initialized pool's currency,
    ///         not merely the configured pool's own pair — so pool B's currency cannot back pool A.
    function test_L02_setRewardToken_rejectsSiblingPoolCurrency() public {
        vm.prank(owner);
        vm.expectRevert(DualPoolIncentivizedHook.RewardTokenIsPoolCurrency.selector);
        hook.setRewardToken(keyA, IERC20(address(b0)));
    }

    /// @notice L-02 (reverse): once a reward token is bound, a new pool cannot be initialized on it
    ///         as a currency, or that reward token's custody would alias the new pool's inventory.
    function test_L02_initializePool_rejectsCurrencyThatIsBoundRewardToken() public {
        vm.prank(owner);
        hook.setRewardToken(keyA, IERC20(address(reward)));

        MockERC20 other = new MockERC20("C", "C", 18);
        (MockERC20 c0, MockERC20 c1) = _sorted(reward, other);
        MockERC4626 vc0 = new MockERC4626(ERC20(address(c0)));
        MockERC4626 vc1 = new MockERC4626(ERC20(address(c1)));
        PoolKey memory keyC = PoolKey({
            currency0: Currency.wrap(address(c0)),
            currency1: Currency.wrap(address(c1)),
            fee: FEE,
            tickSpacing: TS,
            hooks: IHooks(address(hook))
        });

        vm.prank(owner);
        vm.expectRevert(DualPoolIncentivizedHook.PoolCurrencyIsRewardToken.selector);
        hook.initializePool(keyC, _config(vc0, vc1));
    }

    // ──────────────────────────────── L-02: shared-token solvency ──────────────────────────────────

    /// @notice L-02: one reward token may incentivize several pools, and each pool's emissions are
    ///         funded strictly from its own contribution. Both pools fund REWARD of the SAME token;
    ///         after a full period each accrues ~REWARD, draining one pool leaves the other's accrual
    ///         and claimable balance intact, and the shared pot serves both without shortfall.
    function test_L02_sharedRewardTokenPerPoolSolventAndIsolated() public {
        _bootstrap(keyA, a0, a1, SEED);
        _bootstrap(keyB, b0, b1, SEED);
        _configureAndFund(keyA, REWARD);
        _configureAndFund(keyB, REWARD); // SAME token on a second pool — supported, must stay solvent

        assertEq(reward.balanceOf(address(hook)), 2 * REWARD, "both pools' fundings held in the shared token");

        vm.roll(block.number + DURATION); // full period for both

        uint256 earnedA = hook.earned(keyA, owner);
        uint256 earnedB = hook.earned(keyB, owner);
        assertApproxEqAbs(earnedA, REWARD, 1e9, "pool A accrues ~ its own funding");
        assertApproxEqAbs(earnedB, REWARD, 1e9, "pool B accrues ~ its own funding");

        // Drain pool A fully; pool B's reservation must be untouched by A's claim.
        vm.prank(owner);
        uint256 paidA = hook.claimRewards(keyA);
        assertApproxEqAbs(paidA, REWARD, 1e9, "A claim ~ A funding");
        assertApproxEqAbs(hook.earned(keyB, owner), earnedB, 1, "B accrual unaffected by A's claim");

        // Pool B still claims in full: its tokens were reserved, not consumed by pool A's claim.
        vm.prank(owner);
        uint256 paidB = hook.claimRewards(keyB);
        assertApproxEqAbs(paidB, REWARD, 1e9, "B claim ~ B funding");

        assertApproxEqAbs(reward.balanceOf(address(hook)), 0, 1e10, "shared pot served both pools, ~empty");
        assertEq(reward.balanceOf(owner), paidA + paidB, "owner received exactly both claims");
    }
}
