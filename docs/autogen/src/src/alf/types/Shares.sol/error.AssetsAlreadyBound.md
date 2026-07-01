# AssetsAlreadyBound
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

{bindAssets} was called on a vault whose asset pair is already bound. The pair is fixed for
the vault's lifetime, so re-binding is rejected.


```solidity
error AssetsAlreadyBound();
```

