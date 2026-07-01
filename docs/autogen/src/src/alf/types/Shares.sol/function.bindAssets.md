# bindAssets
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Bind the asset pair for a vault. The consumer calls this once at bootstrap, before
pulling assets, so the pair is fixed for the vault's lifetime.

Reverts {AssetsAlreadyBound} on a re-bind so the immutability the NatSpec promises is
enforced rather than assumed. Bootstrap calls this exactly once on an empty vault, so
the guard is a no-op on the happy path.


```solidity
function bindAssets(Shares storage self, VaultId vaultId, address asset0, address asset1) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Shares`|   Shares ledger storage.|
|`vaultId`|`VaultId`|The vault to bind.|
|`asset0`|`address`| First asset.|
|`asset1`|`address`| Second asset.|


