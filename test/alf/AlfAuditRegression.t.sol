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
