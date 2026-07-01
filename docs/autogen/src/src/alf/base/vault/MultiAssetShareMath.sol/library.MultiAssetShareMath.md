# MultiAssetShareMath
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/base/vault/MultiAssetShareMath.sol)

**Title:**
MultiAssetShareMath

**Author:**
Uniswap Labs

Pure share-math helpers for the `Shares` ledger. Extracted so peripheral
contracts (aggregator routers, off-chain quote helpers, alternative vault
implementations) can compute the same conversions without touching the
ledger's storage.
Implements the EIP-4626 virtual-shares pattern in two-asset form. The vault
conversion has a bounded share/asset ratio: every read adds `1` virtual asset
to each side and `10**decimalsOffset` virtual shares to supply. The virtual
position can never withdraw, so any post-bootstrap inflation attempt
(e.g., a donation that surfaces through `_assetBalance`) is captured
proportionally by it, making such attacks uneconomic regardless of bootstrap
size.
All functions are `internal pure` and stateless. The conversion helpers
([convertToAmounts](/src/alf/base/vault/MultiAssetShareMath.sol/library.MultiAssetShareMath.md#converttoamounts)) are overflow-safe via Solady's 512-bit `fullMulDiv` /
`fullMulDivUp`; [bootstrapShares](/src/alf/base/vault/MultiAssetShareMath.sol/library.MultiAssetShareMath.md#bootstrapshares) carries its own overflow precondition documented
on that function (its `received0 * received1` product is a plain checked multiply).

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
|`supply`|`uint256`|         Real share supply (`Shares.totalSupply(vaultId)`).|
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

`received0 * received1` is a plain checked multiply (not `fullMulDiv`); it panics
on overflow. Precondition: `received0 * received1 < 2**256`. This is unreachable
for real inventory because both inputs originate from uint128-packed balances, so
the product is at most `2**256 - 2**129 + 1 < 2**256`. The sqrt itself cannot
overflow once the product fits in uint256.

Returns 0 if `received0 * received1 == 0`; the caller should treat that as
"insufficient bootstrap."


```solidity
function bootstrapShares(uint256 received0, uint256 received1) internal pure returns (uint256);
```

