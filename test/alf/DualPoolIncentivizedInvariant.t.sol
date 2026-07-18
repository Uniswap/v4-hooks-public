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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {DualPoolIncentivizedHook} from "../../src/alf/DualPoolIncentivizedHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {IncentivizedHandler} from "./handlers/IncentivizedHandler.sol";

/// @title DualPoolIncentivizedInvariantTest
/// @notice Invariant suite for the `Rewards` liquidity-incentives capability composed onto
///         DualPoolHook. Fills the gap flagged in the security review: there was no stateful
///         reward-accrual campaign. Asserts the two solvency properties the `RewardRateTooHigh`
///         guard exists to uphold — the reward pot always covers outstanding accrual, and the
///         protocol never schedules/distributes more than was funded — across random sequences of
///         deposits, withdrawals, swaps, owner funding, claims, and block progression.
/// @dev    Single reward token / single pool, so the shared-token guard-weakening (review L-02) is
///         out of scope here; these invariants assert the per-pool solvency that must always hold.
contract DualPoolIncentivizedInvariantTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    DualPoolIncentivizedHook public hook;
    IncentivizedHandler public handler;

    MockERC4626 public vault0;
    MockERC4626 public vault1;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public reward;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    PoolKey testKey;
    PoolId testPoolId;

    uint24 constant FEE_PIPS = 1_000;
    uint256 constant DURATION = 5_000; // reward period length, in blocks
    uint256 constant BOOTSTRAP_AMOUNT = 1e22;

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

        testKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        testPoolId = testKey.toId();

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
        hook.initializePool(testKey, cfg);

        // Bootstrap (owner), then configure rewards (token + duration) so the handler can fund.
        token0.mint(owner, BOOTSTRAP_AMOUNT);
        token1.mint(owner, BOOTSTRAP_AMOUNT);
        vm.startPrank(owner);
        token0.approve(address(hook), BOOTSTRAP_AMOUNT);
        token1.approve(address(hook), BOOTSTRAP_AMOUNT);
        hook.bootstrap(testKey, BOOTSTRAP_AMOUNT, BOOTSTRAP_AMOUNT);
        hook.setRewardToken(testKey, IERC20(address(reward)));
        hook.setRewardsDuration(testKey, DURATION);
        vm.stopPrank();

        vm.roll(block.number + 1);

        address[] memory actorList = new address[](3);
        actorList[0] = owner;
        actorList[1] = alice;
        actorList[2] = bob;

        handler = new IncentivizedHandler(hook, swapRouter, testKey, token0, token1, reward, owner, actorList);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = IncentivizedHandler.addLiquidity.selector;
        selectors[1] = IncentivizedHandler.removeLiquidity.selector;
        selectors[2] = IncentivizedHandler.claim.selector;
        selectors[3] = IncentivizedHandler.notify.selector;
        selectors[4] = IncentivizedHandler.swap.selector;
        selectors[5] = IncentivizedHandler.warpTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Sum of every actor's currently-claimable reward across the closed actor set.
    function _sumEarned() internal view returns (uint256 total) {
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            total += hook.earned(testKey, handler.actors(i));
        }
    }

    /// @notice INV-REWARD-2: the reward pot held by the hook always covers every LP's outstanding
    ///         accrued-but-unclaimed reward. If accrual ever outran funding (the failure mode the
    ///         `RewardRateTooHigh` guard defends against), some LP's `claimRewards` would revert on
    ///         transfer — this catches it before a user hits it.
    function invariant_rewardPotSolvent() public view {
        assertGe(reward.balanceOf(address(hook)), _sumEarned(), "INV-REWARD-2: pot < outstanding accrued rewards");
    }

    /// @notice INV-REWARD-fund: total distributed + still-outstanding accrual never exceeds total
    ///         funded. Nothing is created from nothing; the incentive budget bounds all rewards.
    function invariant_distributionBoundedByFunding() public view {
        assertLe(
            handler.ghost_totalClaimed() + _sumEarned(),
            handler.ghost_totalFunded(),
            "INV-REWARD: claimed + outstanding > funded"
        );
    }

    /// @notice INV-REWARD-3: no LP can have claimed more than the hook was ever funded.
    function invariant_claimedNeverExceedsFunded() public view {
        assertLe(handler.ghost_totalClaimed(), handler.ghost_totalFunded(), "INV-REWARD-3: claimed > funded");
    }

    /// @notice INV-SHARE-1 (carried): share supply parity holds under the incentivized hook too —
    ///         the reward checkpoint seam must not perturb the underlying share ledger.
    function invariant_totalSharesEqualsSumUserShares() public view {
        uint256 sum;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            sum += hook.userShares(testPoolId, handler.actors(i));
        }
        assertEq(hook.totalShares(testPoolId), sum, "INV-SHARE-1: totalShares != sum(userShares)");
    }
}
