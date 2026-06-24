// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultId} from "../types/VaultId.sol";

/// @title RewardsLib
/// @author Uniswap Labs
/// @notice Reusable liquidity-incentives capability: Synthetix-style per-share reward accrual
///         keyed by an opaque `VaultId`, decoupled from where the share balances live. A hook
///         that already tracks LP shares (e.g. via `MultiAssetVault`) composes this by:
///
///           1. calling {checkpoint} from `MultiAssetVault._onShareCheckpoint` — which fires
///              immediately before every share mutation with the pre-mutation total and user
///              balances — and
///           2. exposing owner funding ({notifyRewardAmount}) plus a user {claim} entry point.
///
///         Accrual follows the canonical Synthetix `StakingRewards` math: a global
///         `rewardPerTokenStored` index accumulates `rewardRate` per second spread across the
///         total share supply, and each account is credited `balance * (index - paidIndex)` at
///         every checkpoint. Because the share balances are SUPPLIED BY THE CALLER at checkpoint
///         time (the capability never owns them), the same library works over any share ledger.
///
///         Crucially, the checkpoint only fires on share mutations (bootstrap / deposit /
///         withdraw), never on the swap hot path — incentives add no per-swap gas.
///
///         Storage lives at a fixed ERC-7201 namespaced slot via {load}; the reward token,
///         period, and per-user accounting are isolated per `VaultId`.
/// @custom:security-contact security@uniswap.org
library RewardsLib {
    using SafeERC20 for IERC20;

    /// @dev Fixed-point scale for the per-share index, matching Synthetix.
    uint256 private constant PRECISION = 1e18;

    /// @dev Per-vault reward program state.
    /// @param token                 Reward ERC-20 (`address(0)` = unconfigured).
    /// @param rewardsDuration        Length of a reward period, in seconds.
    /// @param periodFinish           Timestamp the current period ends.
    /// @param rewardRate             Reward tokens distributed per second during the period.
    /// @param lastUpdateTime         Timestamp of the last global index checkpoint.
    /// @param rewardPerTokenStored   Accumulated reward per share, scaled by `PRECISION`.
    /// @param userRewardPerTokenPaid Per-user index snapshot at their last checkpoint.
    /// @param rewards                Per-user settled, claimable reward balance.
    struct Reward {
        IERC20 token;
        uint256 rewardsDuration;
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        mapping(address user => uint256) userRewardPerTokenPaid;
        mapping(address user => uint256) rewards;
    }

    struct Rewards {
        mapping(VaultId vaultId => Reward) reward;
    }

    /// @dev ERC-7201 namespaced storage slot.
    ///      `keccak256(abi.encode(uint256(keccak256("alf.capability.rewards")) - 1)) & ~0xff`.
    bytes32 private constant REWARDS_SLOT = 0x288ba1be555df8a98a9e79b1130d8854b72f82af528c100f07a48fcb62c12900;

    /// @dev `setRewardToken` was given `address(0)`.
    error ZeroRewardToken();
    /// @dev `setRewardToken` was called for a vault that already has a reward token. The binding
    ///      is permanent so accrued balances always resolve against one token.
    error RewardTokenAlreadySet();
    /// @dev An operation requiring a reward token ran before one was configured.
    error RewardTokenNotSet();
    /// @dev `setRewardsDuration` was given zero, or {notifyRewardAmount} ran before a duration
    ///      was configured.
    error RewardsDurationNotSet();
    /// @dev `setRewardsDuration` was called while a reward period is still active; changing the
    ///      cadence mid-period would retroactively rescale the outstanding rate.
    error RewardPeriodActive();
    /// @dev The recomputed `rewardRate` would distribute more than the reward token balance on
    ///      hand over the period — the Synthetix "provided reward too high" guard.
    error RewardRateTooHigh();

    /// @notice Emitted when a vault's reward token is bound.
    event RewardTokenSet(VaultId indexed vaultId, address token);
    /// @notice Emitted when a vault's reward period duration is set.
    event RewardsDurationSet(VaultId indexed vaultId, uint256 duration);
    /// @notice Emitted when a reward period is funded (or topped up).
    event RewardAdded(VaultId indexed vaultId, uint256 reward, uint256 periodFinish);
    /// @notice Emitted when a user claims accrued rewards.
    event RewardPaid(VaultId indexed vaultId, address indexed user, uint256 reward);

    /// @notice Access the capability's namespaced storage.
    function load() internal pure returns (Rewards storage s) {
        assembly ("memory-safe") {
            s.slot := REWARDS_SLOT
        }
    }

    // ─────────────────────────────────────── Configuration ─────────────────────────────────────

    /// @notice The reward token bound to `id`, or `address(0)` if unconfigured.
    function rewardTokenOf(Rewards storage self, VaultId id) internal view returns (IERC20) {
        return self.reward[id].token;
    }

    /// @notice Bind the reward token for `id`. Permanent — accrued balances must always resolve
    ///         against a single token. Caller validates the token is not a pool currency.
    function setRewardToken(Rewards storage self, VaultId id, IERC20 token) internal {
        if (address(token) == address(0)) revert ZeroRewardToken();
        Reward storage r = self.reward[id];
        if (address(r.token) != address(0)) revert RewardTokenAlreadySet();
        r.token = token;
        emit RewardTokenSet(id, address(token));
    }

    /// @notice Set the reward period length for `id`. Only permitted between periods, since
    ///         changing it mid-period would retroactively rescale the active rate.
    function setRewardsDuration(Rewards storage self, VaultId id, uint256 duration) internal {
        if (duration == 0) revert RewardsDurationNotSet();
        Reward storage r = self.reward[id];
        if (block.timestamp < r.periodFinish) revert RewardPeriodActive();
        r.rewardsDuration = duration;
        emit RewardsDurationSet(id, duration);
    }

    // ─────────────────────────────────────── Accrual core ──────────────────────────────────────

    /// @dev `min(block.timestamp, periodFinish)` — accrual stops at period end.
    function _lastTimeApplicable(Reward storage r) private view returns (uint256) {
        uint256 finish = r.periodFinish;
        return block.timestamp < finish ? block.timestamp : finish;
    }

    /// @dev Current global reward-per-share index given the supply over the elapsed window.
    function _rewardPerToken(Reward storage r, uint256 totalSupply) private view returns (uint256) {
        if (totalSupply == 0) return r.rewardPerTokenStored;
        uint256 elapsed = _lastTimeApplicable(r) - r.lastUpdateTime;
        return r.rewardPerTokenStored + (elapsed * r.rewardRate * PRECISION) / totalSupply;
    }

    /// @notice Settle accrual immediately before a share-balance change: advance the global index
    ///         against the OLD `totalSupply`, then credit `user` against their OLD `userShares`.
    ///         Pass `user == address(0)` to checkpoint only the global index (e.g. on funding).
    /// @param self        Capability storage.
    /// @param id          The vault whose program to settle.
    /// @param user        The account to credit, or `address(0)` for index-only.
    /// @param totalSupply Total shares outstanding BEFORE the imminent mutation.
    /// @param userShares  `user`'s share balance BEFORE the imminent mutation.
    function checkpoint(Rewards storage self, VaultId id, address user, uint256 totalSupply, uint256 userShares)
        internal
    {
        Reward storage r = self.reward[id];
        uint256 rpt = _rewardPerToken(r, totalSupply);
        r.rewardPerTokenStored = rpt;
        r.lastUpdateTime = _lastTimeApplicable(r);
        if (user != address(0)) {
            r.rewards[user] += (userShares * (rpt - r.userRewardPerTokenPaid[user])) / PRECISION;
            r.userRewardPerTokenPaid[user] = rpt;
        }
    }

    // ───────────────────────────────────────── Views ───────────────────────────────────────────

    /// @notice Rewards `user` could claim right now, given their current balance and the supply.
    function earned(Rewards storage self, VaultId id, address user, uint256 userShares, uint256 totalSupply)
        internal
        view
        returns (uint256)
    {
        Reward storage r = self.reward[id];
        uint256 rpt = _rewardPerToken(r, totalSupply);
        return r.rewards[user] + (userShares * (rpt - r.userRewardPerTokenPaid[user])) / PRECISION;
    }

    // ────────────────────────────────────── Funding + claim ────────────────────────────────────

    /// @notice Fund a new reward period (or top up the active one). The consumer MUST have
    ///         already transferred `reward` of the reward token to itself (`address(this)`).
    ///         Settles the global index first, recomputes `rewardRate` (folding in any leftover
    ///         from an active period), and bounds the rate against the on-hand balance so accrual
    ///         can never outrun funding.
    /// @param self        Capability storage.
    /// @param id          The vault to fund.
    /// @param reward      Reward tokens added to the period.
    /// @param totalSupply Current total shares outstanding (for the index settle).
    function notifyRewardAmount(Rewards storage self, VaultId id, uint256 reward, uint256 totalSupply) internal {
        Reward storage r = self.reward[id];
        if (address(r.token) == address(0)) revert RewardTokenNotSet();
        uint256 duration = r.rewardsDuration;
        if (duration == 0) revert RewardsDurationNotSet();

        // Settle the global index up to now before changing the rate.
        r.rewardPerTokenStored = _rewardPerToken(r, totalSupply);

        if (block.timestamp >= r.periodFinish) {
            r.rewardRate = reward / duration;
        } else {
            uint256 leftover = (r.periodFinish - block.timestamp) * r.rewardRate;
            r.rewardRate = (reward + leftover) / duration;
        }

        // The rate must be coverable by the reward tokens actually held by the consumer.
        if (r.rewardRate > r.token.balanceOf(address(this)) / duration) revert RewardRateTooHigh();

        r.lastUpdateTime = block.timestamp;
        r.periodFinish = block.timestamp + duration;
        emit RewardAdded(id, reward, r.periodFinish);
    }

    /// @notice Settle and pay out `user`'s accrued rewards. The consumer passes the user's
    ///         CURRENT share balance and CURRENT total supply (a claim changes neither).
    /// @return amount The reward tokens transferred to `user`.
    function claim(Rewards storage self, VaultId id, address user, uint256 totalSupply, uint256 userShares)
        internal
        returns (uint256 amount)
    {
        checkpoint(self, id, user, totalSupply, userShares);
        Reward storage r = self.reward[id];
        amount = r.rewards[user];
        if (amount > 0) {
            r.rewards[user] = 0;
            r.token.safeTransfer(user, amount);
            emit RewardPaid(id, user, amount);
        }
    }
}
