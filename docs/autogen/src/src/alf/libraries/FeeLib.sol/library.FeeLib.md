# FeeLib
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/libraries/FeeLib.sol)

**Title:**
FeeLib

**Author:**
Uniswap Labs

Shared fee helpers for ALF quote and simulation paths, so a quote charges the same total
fee the v4 swap will. Previously duplicated in `SwapSimulator` and `DualPoolHook`.

**Note:**
security-contact: security@uniswap.org


## Functions
### effectiveSwapFee

Compose the directional protocol fee with an LP fee, mirroring `Pool.swap`'s fee
calculation.

Returns `lpFee` unchanged when the directional protocol fee is zero; otherwise blends
them via `ProtocolFeeLibrary.calculateSwapFee` (protocol fee on the gross, LP fee on the
remainder). Selecting the directional half matches how v4 charges the fee per direction.


```solidity
function effectiveSwapFee(uint24 lpFee, uint24 protocolFee, bool zeroForOne) internal pure returns (uint24);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lpFee`|`uint24`|      The LP fee in pips (1e-6).|
|`protocolFee`|`uint24`|The packed bidirectional protocol fee read from `slot0`.|
|`zeroForOne`|`bool`| The swap direction (selects the directional protocol-fee half).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint24`|The combined swap fee in pips.|


