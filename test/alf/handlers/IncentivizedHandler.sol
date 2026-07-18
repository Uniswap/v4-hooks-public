// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DualPoolIncentivizedHook} from "../../../src/alf/DualPoolIncentivizedHook.sol";

/// @title IncentivizedHandler
/// @notice Invariant-test handler for `DualPoolIncentivizedHook`. Drives LP deposits/withdrawals,
///         swaps, owner reward funding, user claims, and block progression across a fixed actor
///         set, tracking cumulative funded/claimed reward totals as ghosts so the reward-solvency
///         invariants can assert the pot always covers outstanding accrual and never over-distributes.
/// @dev    `fail_on_revert = false`; individual calls may revert on edge cases (empty balance,
///         zero-share mint). Reward config (token + duration) is set once in the test `setUp`.
contract IncentivizedHandler is Test {
    using PoolIdLibrary for PoolKey;

    DualPoolIncentivizedHook public immutable hook;
    PoolSwapTest public immutable swapRouter;
    PoolKey public key;
    PoolId public poolId;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public reward;
    address public immutable owner;

    address[] public actors;

    // ──── Ghosts ────
    uint256 public ghost_totalFunded; // reward tokens transferred into the hook via notifyRewardAmount
    uint256 public ghost_totalClaimed; // reward tokens paid out via claimRewards

    constructor(
        DualPoolIncentivizedHook _hook,
        PoolSwapTest _swapRouter,
        PoolKey memory _key,
        MockERC20 _token0,
        MockERC20 _token1,
        MockERC20 _reward,
        address _owner,
        address[] memory _actors
    ) {
        hook = _hook;
        swapRouter = _swapRouter;
        key = _key;
        poolId = _key.toId();
        token0 = _token0;
        token1 = _token1;
        reward = _reward;
        owner = _owner;
        for (uint256 i; i < _actors.length; i++) {
            actors.push(_actors[i]);
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _fundActor(address actor, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            token0.mint(actor, amount0);
            vm.prank(actor);
            token0.approve(address(hook), type(uint256).max);
        }
        if (amount1 > 0) {
            token1.mint(actor, amount1);
            vm.prank(actor);
            token1.approve(address(hook), type(uint256).max);
        }
    }

    // ──── Operations ────

    function addLiquidity(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = _pickActor(actorSeed);
        uint256 totalShares = hook.totalShares(poolId);
        if (totalShares == 0) return;
        uint256 sharesToMint = bound(sharesSeed, 1, totalShares);

        (uint256 want0, uint256 want1) = hook.previewDeposit(key, sharesToMint);
        _fundActor(actor, want0, want1);

        vm.prank(actor);
        try hook.addLiquidity(key, sharesToMint, type(uint256).max, type(uint256).max, type(uint256).max) {} catch {}
    }

    function removeLiquidity(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = _pickActor(actorSeed);
        uint256 userBal = hook.sharesOf(key, actor);
        if (userBal == 0) return;
        uint256 sharesToBurn = bound(sharesSeed, 1, userBal);

        vm.roll(block.number + 1);
        vm.prank(actor);
        try hook.removeLiquidity(key, sharesToBurn, 0, 0, type(uint256).max) {} catch {}
    }

    /// @notice Claim accrued rewards for an actor, tracking the payout.
    function claim(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);
        vm.prank(actor);
        try hook.claimRewards(key) returns (uint256 paid) {
            ghost_totalClaimed += paid;
        } catch {}
    }

    /// @notice Owner funds a reward period. Reward token + duration are configured in setUp, so this
    ///         only tops up. Tracks funded total on success.
    function notify(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e15, 1e24);
        reward.mint(owner, amount);
        vm.startPrank(owner);
        reward.approve(address(hook), amount);
        try hook.notifyRewardAmount(key, amount) {
            ghost_totalFunded += amount;
        } catch {}
        vm.stopPrank();
    }

    /// @notice Swap through the JIT path. Rewards ride the share-change seam only, so swaps must
    ///         never move reward accrual — exercising them here checks that invariant under load.
    function swap(uint256 actorSeed, uint256 dirSeed, int256 amountSeed) external {
        address actor = _pickActor(actorSeed);
        bool zeroForOne = (dirSeed % 2 == 0);
        int256 amount = amountSeed;
        if (amount == 0) amount = 1;
        if (amount > 1e21) amount = 1e21;
        if (amount < -1e21) amount = -1e21;

        _fundActor(actor, 1e22, 1e22);
        vm.startPrank(actor);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(actor);
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta
        ) {}
            catch {}
    }

    /// @notice Advance blocks so reward accrual progresses (rewards run on the block clock).
    function warpTime(uint256 blocksSeed) external {
        uint256 nBlocks = bound(blocksSeed, 1, 500);
        vm.roll(block.number + nBlocks);
        vm.warp(block.timestamp + nBlocks * 12);
    }
}
