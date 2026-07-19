// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {VaultId} from "../../src/alf/types/VaultId.sol";
import {
    Rewards,
    Reward,
    RewardTokenNotSet,
    RewardsDurationNotSet,
    RewardPeriodActive,
    RewardRateTooHigh
} from "../../src/alf/types/Rewards.sol";

/// @notice Harness that owns a `Rewards` storage field and re-exposes the free functions attached
///         to it via `using ... for Rewards global`. The type runs on a caller-supplied
///         "now block" rather than `block.timestamp` (see the source NatSpec on the
///         `BlockNumberish` clock), so every accruing entry point threads `nowBlock` through.
///
///         The harness funds itself with the reward token (minted to `address(this)`) so {claim}
///         can `safeTransfer` to users and so `notifyRewardAmount`'s on-hand-balance guard can be
///         driven with either the real balance or a deliberately understated figure.
contract RewardsHarness {
    Rewards internal _rewards;

    /// @dev Read the bound reward token for `id`.
    function rewardTokenOf(VaultId id) external view returns (IERC20) {
        return _rewards.rewardTokenOf(id);
    }

    /// @dev Bind the reward token for `id` (permanent).
    function setRewardToken(VaultId id, IERC20 token) external {
        _rewards.setRewardToken(id, token);
    }

    /// @dev Set the period length, in blocks, for `id` at the given `nowBlock`.
    function setRewardsDuration(VaultId id, uint256 duration, uint256 nowBlock) external {
        _rewards.setRewardsDuration(id, duration, nowBlock);
    }

    /// @dev Fund (or top up) a period. `onHandBalance` is the figure the rate guard checks against,
    ///      passed explicitly so a scenario can understate it to provoke {RewardRateTooHigh}.
    function notifyRewardAmount(
        VaultId id,
        uint256 reward,
        uint256 totalSupply,
        uint256 onHandBalance,
        uint256 nowBlock
    ) external {
        _rewards.notifyRewardAmount(id, reward, totalSupply, onHandBalance, nowBlock);
    }

    /// @dev Settle the global index (and `user`, if non-zero) at `nowBlock`.
    function checkpoint(VaultId id, address user, uint256 totalSupply, uint256 userShares, uint256 nowBlock) external {
        _rewards.checkpoint(id, user, totalSupply, userShares, nowBlock);
    }

    /// @dev Settle and pay out `user`'s accrued rewards, returning the transferred amount.
    function claim(VaultId id, address user, uint256 totalSupply, uint256 userShares, uint256 nowBlock)
        external
        returns (uint256)
    {
        return _rewards.claim(id, user, totalSupply, userShares, nowBlock);
    }

    /// @dev Rewards `user` could claim right now (view).
    function earned(VaultId id, address user, uint256 userShares, uint256 totalSupply, uint256 nowBlock)
        external
        view
        returns (uint256)
    {
        return _rewards.earned(id, user, userShares, totalSupply, nowBlock);
    }

    /// @dev Read the current per-block rate (for top-up assertions). Reaches into the per-`VaultId`
    ///      `Reward` directly through the source's `_inner` mapping, since the rate is not surfaced
    ///      by a free function. Reading a struct member off a storage reference is always permitted.
    function rewardRateOf(VaultId id) external view returns (uint256) {
        Reward storage r = _rewards._inner[id];
        return r.rewardRate;
    }

    /// @dev Read the current period-finish block (for top-up / extension assertions).
    function periodFinishOf(VaultId id) external view returns (uint256) {
        Reward storage r = _rewards._inner[id];
        return r.periodFinishBlock;
    }
}

/// @title RewardsTest
/// @notice Isolated unit tests for the Synthetix-style `Rewards` capability type: the funding rate
///         guard, between-periods duration setter, mid-period top-up rate folding, and the basic
///         accrue/claim happy path. Mirrors the harness style of `PoolVault.t.sol` and the
///         single-type focus of `JITLock.t.sol`.
contract RewardsTest is Test {
    RewardsHarness internal h;
    MockERC20 internal reward;

    VaultId internal vaultId = VaultId.wrap(bytes32(uint256(0xABCDEF)));
    address internal alice = makeAddr("alice");

    /// @dev A round duration keeps the integer-floored rate math exact. The supply is a single
    ///      share held by one user: the per-share index is then `elapsed * rate * 1e18` and the
    ///      user's credit is `1 * index / 1e18 = elapsed * rate` exactly, with no rounding to zero.
    ///      (A large supply with a small rate would floor the per-share index to 0 and hide
    ///      accrual; the single-share holder is the canonical Synthetix simplification.)
    uint256 internal constant DURATION = 100; // blocks
    uint256 internal constant SUPPLY = 1; // total shares, single holder owns all of it

    function setUp() public {
        h = new RewardsHarness();
        reward = new MockERC20("Reward", "RWD", 18);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev Bind the token and a `DURATION`-block period at block `nowBlock`.
    function _configure(uint256 nowBlock) internal {
        h.setRewardToken(vaultId, IERC20(address(reward)));
        h.setRewardsDuration(vaultId, DURATION, nowBlock);
    }

    /// @dev Mint `amount` of the reward token into the harness's own custody. The source contract
    ///      requires the consumer to hold the reward before notifying.
    function _fundHarness(uint256 amount) internal {
        reward.mint(address(h), amount);
    }

    // ─────────────────────── RewardRateTooHigh guard ───────────────────────

    /// @notice The core "accrual can never outrun funding" check: a notified reward whose implied
    ///         per-block rate exceeds what the on-hand balance can cover over the duration reverts.
    ///         rate = reward / duration; guard trips when rate > onHandBalance / duration.
    function test_notifyRewardAmount_revertsWhenRateExceedsOnHandBalance() public {
        _configure(1);

        // reward = 1000, duration = 100 => rate = 10. onHandBalance = 999 => 999/100 = 9.
        // 10 > 9, so the guard reverts. (Note: integer flooring — the balance must be at least
        // `rate * duration` to pass.)
        uint256 rewardAmount = 1_000;
        uint256 onHand = 999;
        _fundHarness(onHand);
        vm.expectRevert(RewardRateTooHigh.selector);
        h.notifyRewardAmount(vaultId, rewardAmount, SUPPLY, onHand, 1);
    }

    /// @notice The boundary: an on-hand balance exactly covering `rate * duration` passes.
    function test_notifyRewardAmount_passesWhenOnHandCoversRate() public {
        _configure(1);

        uint256 rewardAmount = 1_000; // rate = 10
        uint256 onHand = 1_000; // 1000/100 = 10, 10 > 10 is false => passes
        _fundHarness(onHand);
        h.notifyRewardAmount(vaultId, rewardAmount, SUPPLY, onHand, 1); // no revert
        assertEq(h.rewardRateOf(vaultId), rewardAmount / DURATION, "rate = reward / duration");
        assertEq(h.periodFinishOf(vaultId), 1 + DURATION, "period finishes nowBlock + duration");
    }

    // ───────────────────── duration setter revert guards ─────────────────────

    /// @notice Setting a zero duration reverts {RewardsDurationNotSet}.
    function test_setRewardsDuration_revertsOnZero() public {
        h.setRewardToken(vaultId, IERC20(address(reward)));
        vm.expectRevert(RewardsDurationNotSet.selector);
        h.setRewardsDuration(vaultId, 0, 1);
    }

    /// @notice Setting the duration while a period is still live reverts {RewardPeriodActive}; the
    ///         guard is `nowBlock < periodFinishBlock`.
    function test_setRewardsDuration_revertsWhilePeriodActive() public {
        _configure(1);
        uint256 onHand = 1_000;
        _fundHarness(onHand);
        h.notifyRewardAmount(vaultId, 1_000, SUPPLY, onHand, 1); // period: [1, 101)

        // Midway through the live period: nowBlock = 50 < periodFinish = 101.
        vm.expectRevert(RewardPeriodActive.selector);
        h.setRewardsDuration(vaultId, DURATION, 50);
    }

    /// @notice Once the period has elapsed, the duration can be reset (boundary: nowBlock ==
    ///         periodFinishBlock is NOT active, since the guard is strict `<`).
    function test_setRewardsDuration_succeedsAtAndAfterPeriodFinish() public {
        _configure(1);
        uint256 onHand = 1_000;
        _fundHarness(onHand);
        h.notifyRewardAmount(vaultId, 1_000, SUPPLY, onHand, 1); // period: [1, 101)

        // Exactly at finish: nowBlock == periodFinishBlock (101) is not `<`, so it is permitted.
        h.setRewardsDuration(vaultId, 200, 101); // no revert
    }

    // ──────────────────── notify-before-duration revert ────────────────────

    /// @notice Notifying before any duration is configured reverts {RewardsDurationNotSet}.
    function test_notifyRewardAmount_revertsWhenDurationUnset() public {
        h.setRewardToken(vaultId, IERC20(address(reward)));
        _fundHarness(1_000);
        vm.expectRevert(RewardsDurationNotSet.selector);
        h.notifyRewardAmount(vaultId, 1_000, SUPPLY, 1_000, 1);
    }

    /// @notice Notifying before any reward token is bound reverts {RewardTokenNotSet} (checked
    ///         before the duration guard).
    function test_notifyRewardAmount_revertsWhenTokenUnset() public {
        // No setRewardToken call: token is address(0).
        _fundHarness(1_000);
        vm.expectRevert(RewardTokenNotSet.selector);
        h.notifyRewardAmount(vaultId, 1_000, SUPPLY, 1_000, 1);
    }

    // ─────────────────────────── mid-period top-up ───────────────────────────

    /// @notice A top-up partway through an active period folds in the remaining reward and
    ///         recomputes the rate: leftover = (periodFinish - now) * rate; newRate =
    ///         (reward + leftover) / duration. The rate must reflect leftover + new reward, and the
    ///         period extends to now + duration.
    function test_notifyRewardAmount_topUpFoldsLeftoverAndExtendsPeriod() public {
        _configure(1);

        // First funding: reward = 1000, duration = 100, start block = 1.
        // rate0 = 1000/100 = 10. periodFinish0 = 1 + 100 = 101.
        uint256 reward0 = 1_000;
        _fundHarness(reward0);
        h.notifyRewardAmount(vaultId, reward0, SUPPLY, reward0, 1);

        uint256 rate0 = h.rewardRateOf(vaultId);
        assertEq(rate0, reward0 / DURATION, "rate0 = reward0 / duration");
        assertEq(h.periodFinishOf(vaultId), 101, "period0 finishes at 101");

        // Top up at block 51 (40 blocks distributed, 50 remaining of the 100-block period).
        // leftover = (periodFinish - now) * rate0 = (101 - 51) * 10 = 50 * 10 = 500.
        // The harness must hold the full backing for the recomputed rate: leftover + reward1 = 1500.
        uint256 nowBlock = 51;
        uint256 reward1 = 1_000;
        uint256 leftover = (h.periodFinishOf(vaultId) - nowBlock) * rate0;
        uint256 expectedRate = (reward1 + leftover) / DURATION; // (1000 + 500) / 100 = 15
        // Top up the harness's custody so its on-hand balance covers the new rate over the duration.
        _fundHarness(reward1);
        uint256 onHand = reward.balanceOf(address(h)); // 1000 + 1000 = 2000; 2000/100 = 20 >= 15
        h.notifyRewardAmount(vaultId, reward1, SUPPLY, onHand, nowBlock);

        assertEq(h.rewardRateOf(vaultId), expectedRate, "top-up rate folds in leftover + new reward");
        assertGt(h.rewardRateOf(vaultId), rate0, "top-up raises the rate above the original");
        assertEq(h.periodFinishOf(vaultId), nowBlock + DURATION, "period extends to now + duration");
        assertGt(h.periodFinishOf(vaultId), 101, "extended period finishes later than the original");
    }

    // ───────────────────────────── happy path ─────────────────────────────

    /// @notice Set token, set duration, notify, advance the block, then assert accrual is positive
    ///         and bounded by funding; claim transfers the reward and zeroes the user's accrued.
    ///         With a single holder owning the full supply, earned over N blocks equals N * rate.
    function test_happyPath_accrueAndClaim() public {
        _configure(1);

        uint256 rewardAmount = 1_000;
        _fundHarness(rewardAmount);
        h.notifyRewardAmount(vaultId, rewardAmount, SUPPLY, rewardAmount, 1);
        uint256 rate = h.rewardRateOf(vaultId);

        // Checkpoint Alice into the program at the start so her paid-index is the period's base.
        // (In production the share-mutation checkpoint does this; here it is explicit.)
        h.checkpoint(vaultId, alice, SUPPLY, SUPPLY, 1);

        // Advance 10 blocks within the period. Alice holds the full supply, so the per-share index
        // contribution is `elapsed * rate * 1e18 / SUPPLY`, and her credit is `SUPPLY * index / 1e18`
        // = elapsed * rate exactly.
        uint256 nowBlock = 11; // 10 blocks elapsed
        uint256 elapsed = nowBlock - 1;
        uint256 expectedEarned = elapsed * rate; // 10 * 10 = 100

        uint256 earnedNow = h.earned(vaultId, alice, SUPPLY, SUPPLY, nowBlock);
        assertEq(earnedNow, expectedEarned, "earned = elapsed * rate for the sole holder");
        assertGt(earnedNow, 0, "accrual is positive after advancing the block");
        assertLe(earnedNow, rewardAmount, "accrual is bounded by total funding");

        // Claim pays out exactly the earned amount and zeroes the accrued balance.
        uint256 aliceBalBefore = reward.balanceOf(alice);
        uint256 paid = h.claim(vaultId, alice, SUPPLY, SUPPLY, nowBlock);
        assertEq(paid, expectedEarned, "claim returns the earned amount");
        assertEq(reward.balanceOf(alice) - aliceBalBefore, expectedEarned, "claim transfers the reward token");

        // After claiming, earned at the same block is zero (the paid index advanced to current).
        assertEq(h.earned(vaultId, alice, SUPPLY, SUPPLY, nowBlock), 0, "accrued zeroed after claim");

        // A second claim at the same block is a no-op (nothing to transfer).
        uint256 paidAgain = h.claim(vaultId, alice, SUPPLY, SUPPLY, nowBlock);
        assertEq(paidAgain, 0, "re-claiming at the same block pays nothing");
    }

    /// @notice Accrual stops at `periodFinishBlock`: advancing past the end never pays more than the
    ///         funded total, even though blocks keep ticking.
    function test_happyPath_accrualStopsAtPeriodFinish() public {
        _configure(1);

        uint256 rewardAmount = 1_000; // rate = 10 over 100 blocks
        _fundHarness(rewardAmount);
        h.notifyRewardAmount(vaultId, rewardAmount, SUPPLY, rewardAmount, 1);
        uint256 rate = h.rewardRateOf(vaultId);

        h.checkpoint(vaultId, alice, SUPPLY, SUPPLY, 1);

        // Roll far past the period finish (101). `_lastBlockApplicable` clamps to periodFinish, so
        // earned is capped at `(periodFinish - start) * rate = 100 * 10 = 1000`.
        uint256 nowBlock = 10_000;
        uint256 capped = (h.periodFinishOf(vaultId) - 1) * rate;
        assertEq(h.earned(vaultId, alice, SUPPLY, SUPPLY, nowBlock), capped, "earned clamps at period finish");
        assertLe(capped, rewardAmount, "capped accrual never exceeds funding");
    }
}
