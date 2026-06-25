// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SmartPoolHook} from "../../src/alf/SmartPoolHook.sol";
import {SmartPoolIncentivizedHook} from "../../src/alf/SmartPoolIncentivizedHook.sol";
import {RewardTokenAlreadySet} from "../../src/alf/types/Rewards.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title SmartPoolIncentivizedHookTest
/// @notice Exercises the liquidity-incentives capability composed onto SmartPoolHook: Synthetix
///         per-share accrual settled at the MultiAssetVault share-checkpoint seam, owner funding,
///         user claims, and proof that the inherited JIT swap path is untouched by rewards.
contract SmartPoolIncentivizedHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    SmartPoolIncentivizedHook public hook;
    MockERC4626 public vault0;
    MockERC4626 public vault1;
    MockERC20 public reward;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    PoolKey testKey;
    PoolId testPoolId;
    MockERC20 token0;
    MockERC20 token1;

    uint24 constant FEE_PIPS = 1_000; // 0.1%
    uint256 constant DURATION = 1_000; // seconds → with REWARD below, rate = 1 ether/s
    uint256 constant REWARD = 1_000 ether; // total reward over a full period
    uint256 constant SEED = 1 ether; // bootstrap/deposit share amount

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
        hook = SmartPoolIncentivizedHook(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags))
        );
        deployCodeTo(
            "SmartPoolIncentivizedHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook)
        );

        testKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(testKey, _config());
        testPoolId = testKey.toId();
    }

    // ─────────────────────────────────────────── Helpers ───────────────────────────────────────────

    function _config() internal view returns (SmartPoolHook.PoolConfig memory) {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        return SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 0
        });
    }

    function _bootstrap(address who, uint256 amount) internal {
        token0.mint(who, amount);
        token1.mint(who, amount);
        vm.startPrank(who);
        token0.approve(address(hook), amount);
        token1.approve(address(hook), amount);
        hook.bootstrap(testKey, amount, amount);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _deposit(address who, uint256 shares) internal {
        (uint256 n0, uint256 n1) = hook.previewDeposit(testKey, shares);
        token0.mint(who, n0);
        token1.mint(who, n1);
        vm.startPrank(who);
        token0.approve(address(hook), n0);
        token1.approve(address(hook), n1);
        hook.addLiquidity(testKey, shares, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _configureRewards() internal {
        vm.startPrank(owner);
        hook.setRewardToken(testKey, IERC20(address(reward)));
        hook.setRewardsDuration(testKey, DURATION);
        vm.stopPrank();
    }

    function _fund(uint256 amount) internal {
        reward.mint(owner, amount);
        vm.startPrank(owner);
        reward.approve(address(hook), amount);
        hook.notifyRewardAmount(testKey, amount);
        vm.stopPrank();
    }

    // ─────────────────────────────────────── Configuration ─────────────────────────────────────────

    function test_setRewardToken_rejectsPoolCurrency() public {
        vm.prank(owner);
        vm.expectRevert(SmartPoolIncentivizedHook.RewardTokenIsPoolCurrency.selector);
        hook.setRewardToken(testKey, IERC20(Currency.unwrap(currency0)));
    }

    function test_setRewardToken_isPermanent() public {
        vm.startPrank(owner);
        hook.setRewardToken(testKey, IERC20(address(reward)));
        vm.expectRevert(RewardTokenAlreadySet.selector);
        hook.setRewardToken(testKey, IERC20(address(reward)));
        vm.stopPrank();
    }

    function test_notifyRewardAmount_revertsWithoutToken() public {
        _bootstrap(owner, SEED);
        vm.prank(owner);
        hook.setRewardsDuration(testKey, DURATION);
        reward.mint(owner, REWARD);
        vm.startPrank(owner);
        reward.approve(address(hook), REWARD);
        vm.expectRevert(SmartPoolIncentivizedHook.RewardTokenNotConfigured.selector);
        hook.notifyRewardAmount(testKey, REWARD);
        vm.stopPrank();
    }

    // ────────────────────────────────────────── Accrual ────────────────────────────────────────────

    function test_singleLP_accruesAndClaims() public {
        _bootstrap(owner, SEED);
        _configureRewards();
        _fund(REWARD);

        vm.warp(block.timestamp + DURATION / 2);

        uint256 earned = hook.earned(testKey, owner);
        assertApproxEqAbs(earned, REWARD / 2, 1e6, "half-period accrual ~ half reward");

        vm.prank(owner);
        uint256 paid = hook.claimRewards(testKey);
        assertEq(paid, earned, "claim pays exactly earned");
        assertEq(reward.balanceOf(owner), paid, "reward token received");
        assertEq(hook.earned(testKey, owner), 0, "earned zero immediately after claim");
    }

    function test_twoLPs_accrueProportionalToShares() public {
        _bootstrap(owner, SEED);
        _deposit(alice, SEED); // equal shares to owner
        _configureRewards();
        _fund(REWARD);

        vm.warp(block.timestamp + DURATION); // full period

        uint256 eOwner = hook.earned(testKey, owner);
        uint256 eAlice = hook.earned(testKey, alice);
        assertApproxEqAbs(eOwner, eAlice, 1e9, "equal shares accrue equally");
        assertApproxEqAbs(eOwner + eAlice, REWARD, 1e9, "total accrual ~ funded reward");
    }

    function test_withdraw_freezesAccrual() public {
        _bootstrap(owner, SEED);
        _configureRewards();
        _fund(REWARD);

        vm.warp(block.timestamp + DURATION / 4);

        uint256 shares = hook.sharesOf(testKey, owner);
        vm.prank(owner);
        hook.removeLiquidity(testKey, shares, 0, 0, block.timestamp);

        uint256 earnedAtExit = hook.earned(testKey, owner);
        assertGt(earnedAtExit, 0, "accrued while staked");

        // No shares held → no further accrual even as the period continues.
        vm.warp(block.timestamp + DURATION);
        assertEq(hook.earned(testKey, owner), earnedAtExit, "accrual frozen after full withdraw");
    }

    function test_claim_withNoRewardsConfigured_returnsZero() public {
        _bootstrap(owner, SEED);
        vm.prank(owner);
        uint256 paid = hook.claimRewards(testKey);
        assertEq(paid, 0, "nothing to claim");
    }

    // ───────────────────────────────────── Inherited behavior ──────────────────────────────────────

    /// @dev Rewards ride deposit/withdraw only — the inherited JIT swap path must be unaffected.
    function test_swap_executesViaInheritedJIT() public {
        _bootstrap(owner, 10_000 ether);

        BalanceDelta delta = swap(testKey, true, -1e15, "");
        assertLt(delta.amount0(), 0, "input token0 spent");
        assertGt(delta.amount1(), 0, "output token1 received");
        // Swap must not have accrued or moved any reward state.
        assertEq(hook.earned(testKey, owner), 0, "swap does not touch reward accrual");
    }
}
