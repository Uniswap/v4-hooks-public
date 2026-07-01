# store
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/ActiveLiquidity.sol)

Record bucket `i`'s deployed liquidity in transient storage.

Writes to slot `base + i`. The addition wraps in the unlikely event the keccak base is
near `type(uint256).max`, matching the v4 transient-namespace convention; the bucket index
is bounded well below that. A zero `liq` returns early without touching the slot, so a
zeroed slot unambiguously means "no position deployed for this bucket" and the load-and-clear
invariant holds without depending on callers to skip zero stores.


```solidity
function store(ActiveLiquidity self, uint256 i, uint128 liq) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`ActiveLiquidity`|The pool's active-liquidity base slot.|
|`i`|`uint256`|   The bucket index.|
|`liq`|`uint128`| The liquidity deployed for the bucket.|


