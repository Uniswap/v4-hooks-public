# RewardRateTooHigh
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

The recomputed `rewardRate` would distribute more than the reward token balance on hand
over the period. Mirrors the Synthetix "provided reward too high" guard.


```solidity
error RewardRateTooHigh();
```

