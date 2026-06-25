// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultId} from "./VaultId.sol";

using SafeERC20 for IERC20;

/// @dev `setRewardToken` was given `address(0)`.
error ZeroRewardToken();
/// @dev `setRewardToken` was called for a vault that already has a reward token. The binding is
///      permanent so accrued balances always resolve against one token.
error RewardTokenAlreadySet();
/// @dev An operation requiring a reward token ran before one was configured.
error RewardTokenNotSet();
/// @dev `setRewardsDuration` was given zero, or {notifyRewardAmount} ran before a duration was
///      configured.
error RewardsDurationNotSet();
/// @dev `setRewardsDuration` was called while a reward period is still active; changing the
///      cadence mid-period would retroactively rescale the outstanding rate.
error RewardPeriodActive();
/// @dev The recomputed `rewardRate` would distribute more than the reward token balance on hand
///      over the period. Mirrors the Synthetix "provided reward too high" guard.
error RewardRateTooHigh();

/// @notice Emitted when a vault's reward token is bound.
/// @param vaultId The vault whose reward token was set.
/// @param token   The reward ERC-20 token address.
event RewardTokenSet(VaultId indexed vaultId, address token);
/// @notice Emitted when a vault's reward period duration is set.
/// @param vaultId  The vault whose duration was set.
/// @param duration The new period length, in blocks.
event RewardsDurationSet(VaultId indexed vaultId, uint256 duration);
/// @notice Emitted when a reward period is funded (or topped up).
/// @param vaultId           The vault that was funded.
/// @param reward            The reward tokens added to the period (token's native decimals).
/// @param periodFinishBlock The block the (re)started period now ends.
event RewardAdded(VaultId indexed vaultId, uint256 reward, uint256 periodFinishBlock);
/// @notice Emitted when a user claims accrued rewards.
/// @param vaultId The vault claimed from.
/// @param user    The account that claimed.
/// @param reward  The reward tokens transferred (token's native decimals).
event RewardPaid(VaultId indexed vaultId, address indexed user, uint256 reward);

/// @dev Fixed-point scale for the per-share index, matching Synthetix.
uint256 constant REWARDS_PRECISION = 1e18;

/// @notice Per-vault Synthetix reward-program state. The period and accrual run on the consumer's
///         `BlockNumberish` clock, not `block.timestamp`: the same clock the share ledger's deposit
///         lock uses, chosen because `block.number` (or the chain's native block count, e.g.
///         Arbitrum's `arbBlockNumber`) is monotonic and reliable where sequencer-set timestamps
///         are not. The consumer supplies the current block to every accruing function.
/// @param token                 Reward ERC-20 (`address(0)` = unconfigured).
/// @param rewardsDuration        Length of a reward period, in blocks.
/// @param periodFinishBlock      Block the current period ends.
/// @param rewardRate             Reward tokens distributed per block during the period.
/// @param lastUpdateBlock        Block of the last global index checkpoint.
/// @param rewardPerTokenStored   Accumulated reward per share, scaled by `REWARDS_PRECISION`.
/// @param userRewardPerTokenPaid Per-user index snapshot at their last checkpoint.
/// @param rewards                Per-user settled, claimable reward balance.
struct Reward {
    IERC20 token;
    uint256 rewardsDuration;
    uint256 periodFinishBlock;
    uint256 rewardRate;
    uint256 lastUpdateBlock;
    uint256 rewardPerTokenStored;
    mapping(address user => uint256) userRewardPerTokenPaid;
    mapping(address user => uint256) rewards;
}

/// @title Rewards
/// @author Uniswap Labs
/// @notice Liquidity-incentives capability: Synthetix-style per-share reward accrual keyed by an
///         opaque `VaultId`, decoupled from where the share balances live. A hook that already
///         tracks LP shares (e.g. via a `Shares` ledger) composes this as a plain storage field
///         and:
///
///           1. calls {checkpoint} from `PoolVault._onShareCheckpoint`, which fires
///              immediately before every share mutation with the pre-mutation total and user
///              balances, and
///           2. exposes owner funding ({notifyRewardAmount}) plus a user {claim} entry point.
///
///         Accrual follows the canonical Synthetix `StakingRewards` math, with the clock changed
///         from wall-time to block height: a global `rewardPerTokenStored` index accumulates
///         `rewardRate` per block spread across the total share supply, and each account is
///         credited `balance * (index - paidIndex)` at every checkpoint. The caller supplies both
///         the share balances and the current block at checkpoint time (the type owns neither), so
///         the same type works over any share ledger and any `BlockNumberish` consumer.
///
///         The checkpoint fires only on share mutations (bootstrap, deposit, withdraw), not on
///         swaps, so accrual adds no swap-path gas.
///
///         The consumer holds a `Rewards` storage field and calls these free functions on it
///         directly, as `rewards.checkpoint(...)`. The reward token, period, and per-user
///         accounting are isolated per `VaultId`.
/// @param _inner The per-`VaultId` reward program state.
/// @custom:security-contact security@uniswap.org
struct Rewards {
    mapping(VaultId vaultId => Reward) _inner;
}

using {
    rewardTokenOf,
    setRewardToken,
    setRewardsDuration,
    checkpoint,
    earned,
    notifyRewardAmount,
    claim
} for Rewards global;

// ─────────────────────────────────────── Configuration ─────────────────────────────────────

/// @notice The reward token bound to `id`, or `address(0)` if unconfigured.
/// @param self Capability storage.
/// @param id   The vault to read.
/// @return The bound reward ERC-20, or the zero address if unconfigured.
function rewardTokenOf(Rewards storage self, VaultId id) view returns (IERC20) {
    return self._inner[id].token;
}

/// @notice Bind the reward token for `id`.
/// @dev Permanent: accrued balances must always resolve against a single token. Caller validates
///      the token is not a pool currency. Reverts {ZeroRewardToken} on the zero address and
///      {RewardTokenAlreadySet} if a token is already bound.
/// @param self  Capability storage.
/// @param id    The vault to configure.
/// @param token The reward ERC-20 to bind.
/// @return self_ The capability storage, for chaining.
function setRewardToken(Rewards storage self, VaultId id, IERC20 token) returns (Rewards storage self_) {
    if (address(token) == address(0)) revert ZeroRewardToken();
    Reward storage r = self._inner[id];
    if (address(r.token) != address(0)) revert RewardTokenAlreadySet();
    r.token = token;
    emit RewardTokenSet(id, address(token));
    return self;
}

/// @notice Set the reward period length for `id`.
/// @dev Only permitted between periods, since changing it mid-period would retroactively rescale
///      the active rate. Reverts {RewardsDurationNotSet} on zero and {RewardPeriodActive} while a
///      period is live.
/// @param self     Capability storage.
/// @param id       The vault to configure.
/// @param duration The period length, in blocks.
/// @param nowBlock The consumer's current block (from `_getBlockNumberish()`).
/// @return self_ The capability storage, for chaining.
function setRewardsDuration(Rewards storage self, VaultId id, uint256 duration, uint256 nowBlock)
    returns (Rewards storage self_)
{
    if (duration == 0) revert RewardsDurationNotSet();
    Reward storage r = self._inner[id];
    if (nowBlock < r.periodFinishBlock) revert RewardPeriodActive();
    r.rewardsDuration = duration;
    emit RewardsDurationSet(id, duration);
    return self;
}

// ─────────────────────────────────────── Accrual core ──────────────────────────────────────

/// @dev `min(nowBlock, periodFinishBlock)`; accrual stops at period end.
/// @param r        The reward program to read.
/// @param nowBlock The consumer's current block.
/// @return The latest block rewards still accrue for.
function _lastBlockApplicable(Reward storage r, uint256 nowBlock) view returns (uint256) {
    uint256 finish = r.periodFinishBlock;
    return nowBlock < finish ? nowBlock : finish;
}

/// @dev Current global reward-per-share index given the supply over the elapsed block window.
/// @param r           The reward program to read.
/// @param totalSupply The total shares the period accrues across.
/// @param nowBlock    The consumer's current block.
/// @return The reward-per-share index, scaled by `REWARDS_PRECISION`.
function _rewardPerToken(Reward storage r, uint256 totalSupply, uint256 nowBlock) view returns (uint256) {
    if (totalSupply == 0) return r.rewardPerTokenStored;
    uint256 elapsed = _lastBlockApplicable(r, nowBlock) - r.lastUpdateBlock;
    return r.rewardPerTokenStored + (elapsed * r.rewardRate * REWARDS_PRECISION) / totalSupply;
}

/// @notice Settle accrual immediately before a share-balance change: advance the global index
///         against the OLD `totalSupply`, then credit `user` against their OLD `userShares`.
/// @dev Pass `user == address(0)` to checkpoint only the global index (e.g. on funding).
/// @param self        Capability storage.
/// @param id          The vault whose program to settle.
/// @param user        The account to credit, or `address(0)` for index-only.
/// @param totalSupply Total shares outstanding BEFORE the imminent mutation.
/// @param userShares  `user`'s share balance BEFORE the imminent mutation.
/// @param nowBlock    The consumer's current block (from `_getBlockNumberish()`).
/// @return self_ The capability storage, for chaining.
function checkpoint(
    Rewards storage self,
    VaultId id,
    address user,
    uint256 totalSupply,
    uint256 userShares,
    uint256 nowBlock
) returns (Rewards storage self_) {
    Reward storage r = self._inner[id];
    uint256 rpt = _rewardPerToken(r, totalSupply, nowBlock);
    r.rewardPerTokenStored = rpt;
    r.lastUpdateBlock = _lastBlockApplicable(r, nowBlock);
    if (user != address(0)) {
        r.rewards[user] += (userShares * (rpt - r.userRewardPerTokenPaid[user])) / REWARDS_PRECISION;
        r.userRewardPerTokenPaid[user] = rpt;
    }
    return self;
}

// ───────────────────────────────────────── Views ───────────────────────────────────────────

/// @notice Rewards `user` could claim right now, given their current balance and the supply.
/// @param self        Capability storage.
/// @param id          The vault to read.
/// @param user        The account to value.
/// @param userShares  `user`'s current share balance.
/// @param totalSupply The current total share supply.
/// @param nowBlock    The consumer's current block (from `_getBlockNumberish()`).
/// @return The claimable reward amount (reward token's native decimals).
function earned(
    Rewards storage self,
    VaultId id,
    address user,
    uint256 userShares,
    uint256 totalSupply,
    uint256 nowBlock
) view returns (uint256) {
    Reward storage r = self._inner[id];
    uint256 rpt = _rewardPerToken(r, totalSupply, nowBlock);
    return r.rewards[user] + (userShares * (rpt - r.userRewardPerTokenPaid[user])) / REWARDS_PRECISION;
}

// ────────────────────────────────────── Funding + claim ────────────────────────────────────

/// @notice Fund a new reward period (or top up the active one).
/// @dev The consumer MUST have already transferred `reward` of the reward token to its own
///      custody. Settles the global index first, recomputes `rewardRate` (folding in any leftover
///      from an active period), and bounds the rate against `onHandBalance` so accrual can never
///      outrun funding. The consumer passes its post-transfer reward-token balance (free functions
///      have no `address(this)` of their own). Reverts {RewardTokenNotSet},
///      {RewardsDurationNotSet}, or {RewardRateTooHigh}.
/// @param self          Capability storage.
/// @param id            The vault to fund.
/// @param reward        Reward tokens added to the period (token's native decimals).
/// @param totalSupply   Current total shares outstanding (for the index settle).
/// @param onHandBalance The consumer's current reward-token balance (post-transfer), bounding the rate.
/// @param nowBlock      The consumer's current block (from `_getBlockNumberish()`).
/// @return self_ The capability storage, for chaining.
function notifyRewardAmount(
    Rewards storage self,
    VaultId id,
    uint256 reward,
    uint256 totalSupply,
    uint256 onHandBalance,
    uint256 nowBlock
) returns (Rewards storage self_) {
    Reward storage r = self._inner[id];
    if (address(r.token) == address(0)) revert RewardTokenNotSet();
    uint256 duration = r.rewardsDuration;
    if (duration == 0) revert RewardsDurationNotSet();

    // Settle the global index up to now before changing the rate.
    r.rewardPerTokenStored = _rewardPerToken(r, totalSupply, nowBlock);

    if (nowBlock >= r.periodFinishBlock) {
        r.rewardRate = reward / duration;
    } else {
        uint256 leftover = (r.periodFinishBlock - nowBlock) * r.rewardRate;
        r.rewardRate = (reward + leftover) / duration;
    }

    // The rate must be coverable by the reward tokens actually held by the consumer.
    if (r.rewardRate > onHandBalance / duration) revert RewardRateTooHigh();

    r.lastUpdateBlock = nowBlock;
    r.periodFinishBlock = nowBlock + duration;
    emit RewardAdded(id, reward, r.periodFinishBlock);
    return self;
}

/// @notice Settle and pay out `user`'s accrued rewards.
/// @dev The consumer passes the user's CURRENT share balance and CURRENT total supply (a claim
///      changes neither). Transfers the reward token to `user` and emits {RewardPaid}.
/// @param self        Capability storage.
/// @param id          The vault to claim from.
/// @param user        The account to settle and pay.
/// @param totalSupply The current total share supply.
/// @param userShares  `user`'s current share balance.
/// @param nowBlock    The consumer's current block (from `_getBlockNumberish()`).
/// @return amount The reward tokens transferred to `user` (token's native decimals).
function claim(
    Rewards storage self,
    VaultId id,
    address user,
    uint256 totalSupply,
    uint256 userShares,
    uint256 nowBlock
) returns (uint256 amount) {
    self.checkpoint(id, user, totalSupply, userShares, nowBlock);
    Reward storage r = self._inner[id];
    amount = r.rewards[user];
    if (amount > 0) {
        r.rewards[user] = 0;
        r.token.safeTransfer(user, amount);
        emit RewardPaid(id, user, amount);
    }
}
