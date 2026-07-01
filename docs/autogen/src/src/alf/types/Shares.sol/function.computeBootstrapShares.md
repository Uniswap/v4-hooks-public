# computeBootstrapShares
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Shares.sol)

Compute the bootstrap share supply from received amounts and enforce the
inflation-defense floor. A bootstrap mints `sqrt(received0 * received1)` (V2-style).

Reverts {InsufficientBootstrap} when the geometric mean rounds to zero, and
{BootstrapTooSmall} when it falls below `100 * 10**offset` (~1% drift). Below the floor the
bootstrapper permanently loses non-trivial seed capital to the EIP-4626 virtual position,
and a later attacker can cheaply capture the remainder via small deposits (the virtual-share
defense protects future depositors from each other, not the bootstrapper themselves). Pure
policy, co-located with the ledger that {creditBootstrap} writes.


```solidity
function computeBootstrapShares(uint256 received0, uint256 received1, uint8 offset)
pure
returns (uint256 sharesMinted);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`received0`|`uint256`|Token0 actually received by the vault (post FoT/rebasing reconciliation).|
|`received1`|`uint256`|Token1 actually received by the vault.|
|`offset`|`uint8`|   The vault's decimals offset, which sets the floor scale.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sharesMinted`|`uint256`|The bootstrap share supply to credit.|


