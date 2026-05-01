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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SmartPoolHook} from "../../src/alf/SmartPoolHook.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {SmartPoolHandler} from "./handlers/SmartPoolHandler.sol";

/// @title SmartPoolInvariantTest
/// @notice Foundry invariant suite for SmartPoolHook. Drives the pool through random sequences
///         of LP, swap, and yield operations across a fixed actor set, then asserts protocol-wide
///         invariants on the post-state of every successful sequence.
///
/// @dev    Uses `fail_on_revert = false` because individual handler calls are deliberately
///         allowed to revert on edge cases (e.g., zero-share withdrawal, vault shortfall on a
///         large swap). The invariants must hold over the post-state of every operation, not
///         every attempted call.
contract SmartPoolInvariantTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SmartPoolHook public hook;
    SmartPoolHandler public handler;

    MockERC4626 public vault0;
    MockERC4626 public vault1;

    MockERC20 public token0;
    MockERC20 public token1;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    PoolKey testPoolKey;
    PoolId testPoolId;

    uint24 constant FEE_PIPS = 1_000;

    /// @dev Bootstrap with a supply that comfortably exceeds the virtual-shares offset (1e12),
    ///      so the inflation-defense math doesn't dominate ratios. M-07 in the audit report
    ///      explains why smaller bootstraps are problematic; the invariant suite assumes
    ///      operators have followed best practice.
    uint256 constant BOOTSTRAP_AMOUNT = 1e22; // 10k 18-decimal tokens each side

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        // Deploy hook at flag-mined address.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = SmartPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("SmartPoolHook", abi.encode(manager, uint32(100_000), owner), address(hook));

        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        testPoolId = testPoolKey.toId();

        // Use a 3-bucket "conservative" distribution to exercise multi-bucket allocation paths.
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](3);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7_500});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1_500});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1_000});

        SmartPoolHook.PoolConfig memory cfg = SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true, // Critical: handler actors are external addresses
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1))
        });

        vm.prank(owner);
        hook.initializePool(testPoolKey, cfg);

        // Bootstrap with comfortably-large amounts so virtual-shares drift is negligible.
        token0.mint(owner, BOOTSTRAP_AMOUNT);
        token1.mint(owner, BOOTSTRAP_AMOUNT);
        vm.startPrank(owner);
        token0.approve(address(hook), BOOTSTRAP_AMOUNT);
        token1.approve(address(hook), BOOTSTRAP_AMOUNT);
        hook.bootstrap(testPoolKey, BOOTSTRAP_AMOUNT, BOOTSTRAP_AMOUNT);
        vm.stopPrank();

        // Step a block so the bootstrapper's deposit-block guard doesn't block first ops.
        vm.roll(block.number + 1);

        // Build the actor set and the handler.
        address[] memory actorList = new address[](4);
        actorList[0] = owner;
        actorList[1] = alice;
        actorList[2] = bob;
        actorList[3] = charlie;

        handler = new SmartPoolHandler(
            hook, manager, swapRouter, testPoolKey, token0, token1, vault0, vault1, actorList
        );

        // Restrict invariant fuzzing to handler functions — without this, forge-fuzz would
        // try to call any external function on any deployed contract, exploding the search
        // space and producing false positives.
        targetContract(address(handler));

        // Selectors the handler exposes. Forge will pick from this set uniformly.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = SmartPoolHandler.addLiquidity.selector;
        selectors[1] = SmartPoolHandler.removeLiquidity.selector;
        selectors[2] = SmartPoolHandler.swap.selector;
        selectors[3] = SmartPoolHandler.simulateYield.selector;
        selectors[4] = SmartPoolHandler.warpTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice INV-SHARE-1: `totalShares == sum_over_actors(userShares) + ownerShares`.
    /// @dev    The handler operates on a closed actor set, so this can be checked exactly
    ///         (no unbounded `msg.sender` to track). The owner's bootstrap shares are
    ///         already part of `actors[0]`.
    function invariant_totalSharesEqualsSumUserShares() public view {
        uint256 sumActors;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            sumActors += hook.userShares(testPoolId, handler.actors(i));
        }
        assertEq(hook.totalShares(testPoolId), sumActors, "INV-SHARE-1: totalShares != sum(userShares)");
    }

    /// @notice INV-DIST-1: distribution weights always sum to exactly 10_000 bps.
    function invariant_distributionWeightsSumTo10000() public view {
        SmartPoolHook.LiquidityBucket[] memory dist = hook.getDistribution(testPoolId);
        uint256 totalWeight;
        for (uint256 i; i < dist.length; i++) {
            totalWeight += dist[i].weightBps;
        }
        assertEq(totalWeight, 10_000, "INV-DIST-1: distribution weights != 10_000");
    }

    /// @notice INV-DIST-2: bucket count is bounded `[1, MAX_BUCKETS=8]`.
    function invariant_distributionBucketCountBounded() public view {
        SmartPoolHook.LiquidityBucket[] memory dist = hook.getDistribution(testPoolId);
        assertGe(dist.length, 1, "INV-DIST-2: zero buckets");
        assertLe(dist.length, 8, "INV-DIST-2: too many buckets");
    }

    /// @notice INV-LIVE-1: `livePools` is true for the test pool throughout the run.
    /// @dev    The handler does not call `setPoolLive`, so liveness must remain unchanged.
    ///         A regression that flips it inside any operation would fail this invariant.
    function invariant_poolStaysLive() public view {
        assertTrue(hook.livePools(testPoolId), "INV-LIVE-1: pool was unexpectedly paused");
    }

    /// @notice INV-SOLVENCY: pool's tracked assets >= LP claims.
    /// @dev    Sum of user share withdrawals at current ratios cannot exceed total assets.
    ///         We check this by running a hypothetical 100%-withdrawal preview against
    ///         current totals and verifying the math doesn't violate solvency.
    function invariant_solvency() public view {
        uint256 totalShares = hook.totalShares(testPoolId);
        if (totalShares == 0) return;

        // What would the entire share supply withdraw? Must be <= total assets reported by
        // getReserves (which sums vault.convertToAssets + claims + ERC-20 ledger).
        (uint256 totalAssets0, uint256 totalAssets1) = hook.getReserves(testPoolKey);
        (uint256 maxOut0, uint256 maxOut1) = hook.previewWithdraw(testPoolKey, totalShares);

        assertLe(maxOut0, totalAssets0, "INV-SOLVENCY: previewWithdraw0 > totalAssets0");
        assertLe(maxOut1, totalAssets1, "INV-SOLVENCY: previewWithdraw1 > totalAssets1");
    }

    /// @notice INV-DIST-WEIGHT-NONZERO: every bucket has a non-zero weight.
    /// @dev    The validator rejects zero-weight buckets at write time; this is a
    ///         post-condition cross-check.
    function invariant_distributionAllWeightsNonZero() public view {
        SmartPoolHook.LiquidityBucket[] memory dist = hook.getDistribution(testPoolId);
        for (uint256 i; i < dist.length; i++) {
            assertGt(dist[i].weightBps, 0, "INV-DIST: zero-weight bucket present");
        }
    }

}
