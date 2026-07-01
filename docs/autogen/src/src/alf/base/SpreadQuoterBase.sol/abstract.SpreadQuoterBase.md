# SpreadQuoterBase
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/base/SpreadQuoterBase.sol)

**Inherits:**
[OwnedALFHook](/src/alf/base/OwnedALFHook.sol/abstract.OwnedALFHook.md)

**Title:**
SpreadQuoterBase

**Author:**
Uniswap Labs

Abstract base for spread quoters using native v4 LP with a static, per-pool fee.
Provides pricing via SwapSimulator and single-tick LP concentration. Concrete
hooks define LP access control and hook permissions.

Pools use a static fee defined by `PoolKey.fee` at deploy time. The v4 PoolManager
charges this fee natively on every swap. Owner has only a per-pool liveness flag
(`setPoolLive`) for pause/resume; pricing itself is immutable post-initialize.

**Note:**
security-contact: security@uniswap.org


## State Variables
### activeLowerTick
Lower tick of the single permitted LP range per pool. LP add liquidity calls
must use exactly `[activeLowerTick, activeLowerTick + tickSpacing]`.


```solidity
mapping(PoolId => int24) public activeLowerTick
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, uint32 maxGas_, address owner_)
    OwnedALFHook(_poolManager, maxGas_, owner_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolManager`|`IPoolManager`|The Uniswap v4 PoolManager.|
|`maxGas_`|`uint32`|     Gas budget declared for `getIndicativeQuote` staticcalls.|
|`owner_`|`address`|      Initial owner. Owner can toggle liveness and the active tick.|


### swapToPrice

Simulate a swap up to a target price, returning both amounts.

Delegates to `SwapSimulator.simulateSwapToPrice`. The `DYNAMIC_FEE_FLAG` and
`OVERRIDE_FEE_FLAG` bits are stripped from `key.fee` before forwarding; both
sit above `MAX_LP_FEE`, so the strip is a no-op for any valid static fee and a
belt-and-suspenders guard against a misconfigured pool slipping a flag bit past
`initializePool`'s rejection.


```solidity
function swapToPrice(
    PoolKey calldata key,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata
) external view virtual override returns (uint256 amountIn, uint256 amountOut);
```

### initializePool

Initialize a new SpreadQuoter pool at the operator's chosen price.

`onlyOwner`-gated and routes through `poolManager.initialize` so v4's
`Hooks.noSelfCall` exempts the call from `_beforeInitialize`'s revert. The
active-tick derivation is performed inline from the tick returned by
`poolManager.initialize`. The pool starts paused (`livePools[id] == false`);
enable via [setPoolLive](/src/alf/base/SpreadQuoterBase.sol/abstract.SpreadQuoterBase.md#setpoollive) after seeding LP at the derived active tick.
Dynamic-fee pools are rejected.


```solidity
function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external onlyOwner returns (int24 tick);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|           The PoolKey (must reference this hook; `key.fee` must NOT carry the `LPFeeLibrary.DYNAMIC_FEE_FLAG`).|
|`sqrtPriceX96`|`uint160`|  Initial sqrt price (Q64.96). This price is permanent for the pool's lifetime.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`tick`|`int24`|         The initial tick assigned by the PoolManager.|


### _setActiveTickFromInitialTick

Floor-align `tick` to `key.tickSpacing` and clamp into the v4 usable tick range so
the resulting LP range `[activeLowerTick, activeLowerTick + tickSpacing]` is always
a valid v4 LP position, even at the extremes near MIN/MAX_TICK. Emits no event;
`setActiveTick` is the canonical source for `ActiveTickUpdated` post-init.


```solidity
function _setActiveTickFromInitialTick(PoolKey calldata key, int24 tick) private;
```

### _beforeSwap

Reverts when the pool is paused; otherwise no-ops. v4 charges the static fee from
`key.fee`, so no override is returned. hookData is ignored; pricing is fully static.


```solidity
function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
    internal
    view
    virtual
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

### _price


```solidity
function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool, address)
    internal
    view
    virtual
    override
    returns (uint256 outputAmount);
```

### _staticFee

Strip `DYNAMIC_FEE_FLAG` and `OVERRIDE_FEE_FLAG` from a raw `key.fee` before
forwarding to `SwapSimulator`, which assumes `fee <= MAX_SWAP_FEE`. Both flag
bits sit above `MAX_LP_FEE`, so the strip is a no-op for any valid static fee
and a belt-and-suspenders guard against a flag bit slipping past
`initializePool`'s dynamic-fee rejection.


```solidity
function _staticFee(uint24 rawFee) private pure returns (uint24);
```

### _enforceActiveTick

Enforce single-tick-spacing LP at the active tick.


```solidity
function _enforceActiveTick(PoolKey calldata key, ModifyLiquidityParams calldata params) internal view;
```

### setPoolLive

Toggle liveness for a pool.

Pools default to paused (`false`) immediately after `manager.initialize`. The
owner enables a pool by calling `setPoolLive(key, true)`. Disabling pauses swaps
via `_beforeSwap`'s liveness check; pricing (the static `key.fee`) is unaffected.


```solidity
function setPoolLive(PoolKey calldata key, bool live) external virtual onlyOwner;
```

### setActiveTick

Set the active lower tick for LP concentration.

Relocates the band that new LP adds will be enforced to (via
`_enforceActiveTick` in subclasses). Refuses to relocate while the prior
active band still references liquidity in v4: operators must drain the old
band first (have authorized LPs remove all positions at the old tick) before
calling this with a different `newActiveLowerTick`. Setting the same tick is
always permitted (idempotent no-op). For the multi-LP trust trade-offs (e.g.
revocation locking prior-band positions) see the consuming subclass's
`Trust model` NatSpec.


```solidity
function setActiveTick(PoolKey calldata key, int24 newActiveLowerTick) external virtual onlyOwner;
```

## Events
### ActiveTickUpdated
Emitted when the active lower tick is changed via `setActiveTick`. The initial
tick set by `initializePool` does not emit: the tick is observable via the
`activeLowerTick` getter and `setActiveTick` is the canonical mutation event.


```solidity
event ActiveTickUpdated(PoolId indexed poolId, int24 activeLowerTick);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|          The pool whose active range changed.|
|`activeLowerTick`|`int24`| The new lower tick (always aligned to `tickSpacing`).|

## Errors
### InvalidTickRange
LP add-liquidity range is malformed (lower >= upper, not aligned to `tickSpacing`,
or the range width does not equal one tickSpacing).


```solidity
error InvalidTickRange();
```

### WrongActiveTick
LP add-liquidity range is correctly shaped but not at the configured `activeLowerTick`.


```solidity
error WrongActiveTick();
```

### ActiveTickBandNonEmpty
`setActiveTick` was called while the prior active band still holds liquidity.
Relocating without draining would orphan that liquidity in a range no longer
enforced by the hook, leaving multiple unmigrated bands coexisting and diverging
on-chain liquidity from the hook's single-band policy. Drain the old band first
(have authorized LPs remove all positions at the old tick), then relocate.


```solidity
error ActiveTickBandNonEmpty(int24 activeLowerTick);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`activeLowerTick`|`int24`|The prior active tick that still has liquidity referenced at it.|

### DynamicFeeNotSupported
`key.fee` carries the `LPFeeLibrary.DYNAMIC_FEE_FLAG` (0x800000). SpreadQuoter is
designed around a static fee fixed at pool creation; dynamic-fee pools require the
hook to maintain its own fee state and route every swap through a fee-update
callback, which this contract is not built for. If a dynamic-fee pool
slipped through, `slot0.lpFee` would stay at its `0` default for the pool's
lifetime and every swap would charge zero LP fee. Use a concrete `uint24` fee
value below `MAX_LP_FEE` instead.


```solidity
error DynamicFeeNotSupported();
```

### InvalidHookAddress
The PoolKey's hooks address does not match this contract: `initializePool` was
called with a key intended for a different hook.


```solidity
error InvalidHookAddress();
```

