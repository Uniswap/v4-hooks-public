# effectiveBalance
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Inventory.sol)

Net realizable balance: raw + claims + `previewRedeem(shares)`.

The vault leg is what the vault would deliver right now (post exit fee). Used for
JIT-deployment sizing and indicative quotes so the cycle never sizes against funds it
cannot source. Contrast {assetBalance}, which uses `convertToAssets`.


```solidity
function effectiveBalance(Inventory storage self, bytes32 bucket) view returns (uint256 bal);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Inventory`|  Capability storage.|
|`bucket`|`bytes32`|The accounting partition to value.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`bal`|`uint256`|The immediately-realizable balance (token's native decimals).|


