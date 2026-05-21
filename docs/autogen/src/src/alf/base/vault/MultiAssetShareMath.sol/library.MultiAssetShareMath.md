# MultiAssetShareMath
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/fb38bd58a3855b38f1e6e41a9ca471e83744f2b7/src/alf/base/vault/MultiAssetShareMath.sol)

**Title:**
MultiAssetShareMath

**Author:**
Uniswap Labs

Pure share-math helpers for `MultiAssetVault`. Extracted so peripheral
contracts (aggregator routers, off-chain quote helpers, alternative vault
implementations) can compute the same conversions without inheriting the
vault's state machine.
Implements the EIP-4626 virtual-shares pattern in two-asset form. The vault
conversion has a bounded share/asset ratio: every read adds `1` virtual asset
to each side and `10**decimalsOffset` virtual shares to supply. The virtual
position can never withdraw, so any post-bootstrap inflation attempt
(e.g., a donation that surfaces through `_assetBalance`) is captured
proportionally by it -- making such attacks uneconomic regardless of bootstrap
size.
All functions are `internal pure`. Stateless. Overflow-safe via Solady's
512-bit `fullMulDiv` / `fullMulDivUp`.

**Note:**
security-contact: security@uniswap.org


## Functions
### convertToAmounts

Convert a share count to the equivalent two-asset amounts at the current
vault state, applying virtual-shares offsets.
Formula (per asset):
amount = shares * (total + 1) / (supply + 10**decimalsOffset)


```solidity
function convertToAmounts(
    uint256 shares,
    uint256 total0,
    uint256 total1,
    uint256 supply,
    uint8 decimalsOffset,
    bool roundUp
) internal pure returns (uint256 amount0, uint256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`shares`|`uint256`|         The number of shares to convert.|
|`total0`|`uint256`|         Real asset0 balance (output of `_assetBalance` for asset 0).|
|`total1`|`uint256`|         Real asset1 balance.|
|`supply`|`uint256`|         Real share supply (`_totalShares[vaultId]`).|
|`decimalsOffset`|`uint8`| Virtual-shares decimal offset (typically 12).|
|`roundUp`|`bool`|        True for deposits (round up to prevent dilution), false for withdrawals (round down to prevent over-withdrawal).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|The asset0 amount equivalent to `shares`.|
|`amount1`|`uint256`|The asset1 amount equivalent to `shares`.|


### bootstrapShares

Bootstrap shares for the first deposit at the bootstrapper-chosen ratio:
`sqrt(received0 * received1)` (Uniswap V2 style). Uses Solady's overflow-
safe integer sqrt.

Returns 0 if `received0 * received1 == 0`; the caller should treat that as
"insufficient bootstrap."


```solidity
function bootstrapShares(uint256 received0, uint256 received1) internal pure returns (uint256);
```

