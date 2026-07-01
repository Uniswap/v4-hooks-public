# Assets
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

The asset pair backing a vault, bound at bootstrap and immutable thereafter.


```solidity
struct Assets {
address asset0;
address asset1;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`asset0`|`address`|First asset (subclass-defined identifier; PoolVault uses the unwrapped currency).|
|`asset1`|`address`|Second asset.|

