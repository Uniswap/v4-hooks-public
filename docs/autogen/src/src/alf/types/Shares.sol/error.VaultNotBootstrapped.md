# VaultNotBootstrapped
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

A share operation read or mutated a vault that has not been bootstrapped (`totalShares == 0`).


```solidity
error VaultNotBootstrapped();
```

