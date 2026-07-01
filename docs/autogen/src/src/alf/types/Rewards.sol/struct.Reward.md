# Reward
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

Per-vault Synthetix reward-program state. The period and accrual run on the consumer's
`BlockNumberish` clock, not `block.timestamp`: the same clock the share ledger's deposit
lock uses, chosen because `block.number` (or the chain's native block count, e.g.
Arbitrum's `arbBlockNumber`) is monotonic and reliable where sequencer-set timestamps
are not. The consumer supplies the current block to every accruing function.


```solidity
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
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`token`|`IERC20`|                Reward ERC-20 (`address(0)` = unconfigured).|
|`rewardsDuration`|`uint256`|       Length of a reward period, in blocks.|
|`periodFinishBlock`|`uint256`|     Block the current period ends.|
|`rewardRate`|`uint256`|            Reward tokens distributed per block during the period.|
|`lastUpdateBlock`|`uint256`|       Block of the last global index checkpoint.|
|`rewardPerTokenStored`|`uint256`|  Accumulated reward per share, scaled by `REWARDS_PRECISION`.|
|`userRewardPerTokenPaid`|`mapping(address user => uint256)`|Per-user index snapshot at their last checkpoint.|
|`rewards`|`mapping(address user => uint256)`|               Per-user settled, claimable reward balance.|

