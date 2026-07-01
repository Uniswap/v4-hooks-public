# RewardTokenAlreadySet
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Rewards.sol)

`setRewardToken` was called for a vault that already has a reward token. The binding is
permanent so accrued balances always resolve against one token.


```solidity
error RewardTokenAlreadySet();
```

