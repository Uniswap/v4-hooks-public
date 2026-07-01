# DepositLocked
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

A withdrawal arrived before the depositor's lock elapsed
(`blockNumber < lastDepositBlock + minDepositBlocks`). Defends against atomic
deposit-swap-withdraw fee/yield sniping.


```solidity
error DepositLocked(uint256 unlockBlock);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`unlockBlock`|`uint256`|The clock block at which the lock clears.|

