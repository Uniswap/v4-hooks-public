# OwnedALFHook
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/base/OwnedALFHook.sol)

**Inherits:**
[BaseALFHook](/src/alf/base/BaseALFHook.sol/abstract.BaseALFHook.md), Ownable2Step

**Title:**
OwnedALFHook

**Author:**
Uniswap Labs

Shared owner-administered ALF base for hooks that run a fixed-config, per-pool-liveness
model (DualPoolHook and the SpreadQuoter family). Layers `Ownable2Step` with
`renounceOwnership` disabled, the per-pool `Liveness` capability, and a direct-initialize
guard on top of the `BaseALFHook` metadata/settlement surface (`maxGas`, reserves,
indicative quoting, the `ALFHookData`/attestation envelope, `DeltaResolver._pay`).
Concrete subclasses add their own pricing, distribution / LP gating, and the guarded
`initializePool` entry point.

Pricing is static per `PoolKey.fee` and immutable post-initialize; the owner has only a
per-pool liveness flag for pause/resume. The owner is the single trust principal, so
`renounceOwnership` is disabled.

**Note:**
security-contact: security@uniswap.org


## State Variables
### _liveness
Per-pool pause/resume flag. Pools default to paused; the subclass's guarded
bootstrap/init and its `setPoolLive` toggle it via the `Liveness` capability. Read
externally through [livePools](/src/alf/base/OwnedALFHook.sol/abstract.OwnedALFHook.md#livepools).


```solidity
Liveness internal _liveness
```


## Functions
### constructor


```solidity
constructor(IPoolManager manager, uint32 maxGas_, address owner_) BaseALFHook(manager, maxGas_) Ownable(owner_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`manager`|`IPoolManager`|The Uniswap v4 PoolManager.|
|`maxGas_`|`uint32`|Gas budget declared for `getIndicativeQuote` staticcalls.|
|`owner_`|`address`| Initial contract owner. Transferable via OZ's two-step {Ownable2Step.transferOwnership} / {Ownable2Step.acceptOwnership} flow.|


### _beforeInitialize

Reject direct `poolManager.initialize`. Per v4 `Hooks.noSelfCall`, the hook's own
`poolManager.initialize` from `initializePool` skips this callback, so the only caller
path that reaches here is an external party's direct attempt.


```solidity
function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4);
```

### renounceOwnership

Disabled. The hook's design requires a live owner indefinitely; renouncing would
permanently brick every `onlyOwner` entry point and orphan every pool referencing
this hook. Use {Ownable2Step.transferOwnership} to rotate operators instead.

See [RenounceOwnershipDisabled](/src/alf/base/OwnedALFHook.sol/abstract.OwnedALFHook.md#renounceownershipdisabled) for the rationale.


```solidity
function renounceOwnership() public pure override;
```

### isLive

Whether this hook is currently live and accepting swaps.

Always reports live; hook-level liveness is per-pool via [livePools](/src/alf/base/OwnedALFHook.sol/abstract.OwnedALFHook.md#livepools). Routers call this
to reject offline hooks; this hook is always reachable, but individual pools may pause.


```solidity
function isLive() external pure override returns (bool);
```

### livePools

Whether `poolId` is currently quoting and executing swaps.


```solidity
function livePools(PoolId poolId) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|Whether the pool is live.|


## Errors
### DirectInitializeBlocked
Direct `poolManager.initialize` for a pool using this hook is rejected; callers MUST go
through the subclass's guarded `initializePool` so pricing, distribution, and vault
config are validated and the pool's initial `sqrtPriceX96` (immutable post-init) cannot
be front-run by a third party at a price the operator did not choose.


```solidity
error DirectInitializeBlocked();
```

### RenounceOwnershipDisabled
`renounceOwnership` was called. Renouncing would permanently disable every `onlyOwner`
entry point and orphan every pool referencing this hook. The operator is the single
trust principal in this model; their continuing presence is load-bearing.


```solidity
error RenounceOwnershipDisabled();
```

