# BootstrapTooSmall
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Bootstrap shares (`sqrt(received0 * received1)`) are below the inflation-defense floor of
`100 * 10**offset`. Below this floor the bootstrapper permanently loses more than ~1% of
their seed capital to the virtual position, so operators MUST seed larger amounts.


```solidity
error BootstrapTooSmall(uint256 sharesMinted, uint256 minShares);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sharesMinted`|`uint256`|The bootstrap shares the operator's amounts would have produced.|
|`minShares`|`uint256`|   The minimum shares the offset requires (`100 * 10**offset`).|

