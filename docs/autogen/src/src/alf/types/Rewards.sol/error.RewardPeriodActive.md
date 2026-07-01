# RewardPeriodActive
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

`setRewardsDuration` was called while a reward period is still active; changing the
cadence mid-period would retroactively rescale the outstanding rate.


```solidity
error RewardPeriodActive();
```

