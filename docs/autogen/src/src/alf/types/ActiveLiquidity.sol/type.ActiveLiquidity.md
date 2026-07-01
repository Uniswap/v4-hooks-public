# ActiveLiquidity
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/ActiveLiquidity.sol)

**Title:**
ActiveLiquidity

**Author:**
Uniswap Labs

The transient-storage base slot for a pool's per-bucket JIT liquidity, as a type-driven
value. A JIT hook derives one `ActiveLiquidity` per swap cycle via {activeLiquidityFor},
records each deployed bucket's liquidity with {store} during `beforeSwap`, and reads it
back with {takeAndClear} during `afterSwap` to size the inverse `modifyLiquidity`.
The slot for bucket `i` is `base + i`, so a single keccak per cycle yields the base and
every per-bucket access is a plain addition plus one `tstore`/`tload`. Transient storage
is used because the values live only for the duration of one `beforeSwap`/`afterSwap`
pair, which avoids the cold/warm SSTORE penalty (~22K cold, ~5K warm) per bucket that
persistent storage would incur.
## Load-and-clear
{takeAndClear} zeroes each slot on read rather than relying on end-of-transaction
auto-clear. Transient storage scopes to the transaction, not the v4 unlock, so for
multiple swaps on the same pool within one transaction a stale value would otherwise
persist across cycles: if bucket `i` deployed `liq = 100` in swap 1 and the price moved
so bucket `i` deploys `liq = 0` in swap 2, the deploy path skips the write (it only
{store}s when `liq > 0`), leaving slot `i` at `100` from swap 1. Without the clear,
swap 2's teardown would read `100` and try to remove a position that no longer exists,
reverting the swap. {store} drops zero writes itself, so a zeroed slot unambiguously
means "no position deployed" regardless of caller discipline: the invariant is
self-enforcing rather than relying on every caller to skip zero stores.

**Note:**
security-contact: security@uniswap.org


```solidity
type ActiveLiquidity is bytes32
```

