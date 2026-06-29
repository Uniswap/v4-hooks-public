# DualPoolBase
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/fb38bd58a3855b38f1e6e41a9ca471e83744f2b7/src/alf/base/DualPoolBase.sol)

**Inherits:**
[BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md), DeltaResolver, Ownable2Step, [IALFHook](/src/alf/interfaces/IALFHook.sol/interface.IALFHook.md)

**Title:**
DualPoolBase

**Author:**
Uniswap Labs

Minimal ALF/v4 base for DualPoolHook.

Pool fees are static per `PoolKey.fee` and immutable post-initialize. The owner has
only a per-pool liveness flag for pause/resume; pricing itself cannot be reconfigured
after deployment.

**Note:**
security-contact: security@uniswap.org


## State Variables
### _maxGas
Gas budget declared for `getIndicativeQuote` staticcalls. Returned by `maxGas()`.


```solidity
uint32 private immutable _maxGas
```


### livePools
Whether each pool is currently quoting and executing swaps. Set by the
subclass's guarded `initializePool` and toggled via {DualPoolHook.setPoolLive}.


```solidity
mapping(PoolId => bool) public livePools
```


## Functions
### _beforeInitialize

Reject direct `poolManager.initialize`. Per v4 `Hooks.noSelfCall`, the hook's own
`poolManager.initialize` from `initializePool` skips this callback, so the only
caller path that reaches here is an external party's direct attempt.


```solidity
function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4);
```

### constructor


```solidity
constructor(IPoolManager manager, uint32 maxGas_, address owner_) BaseHook(manager) Ownable(owner_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`manager`|`IPoolManager`|The Uniswap v4 PoolManager.|
|`maxGas_`|`uint32`|Gas budget declared for `getIndicativeQuote` staticcalls.|
|`owner_`|`address`| Initial contract owner. Transferable via OZ's two-step {Ownable2Step.transferOwnership} / {Ownable2Step.acceptOwnership} flow.|


### maxGas

The declared maximum gas for getIndicativeQuote execution.

Callers use this to set gas limits on staticcall invocations.


```solidity
function maxGas() external view override returns (uint32);
```

### supportsInterface

ERC-165 advertisement for the interfaces this contract implements.

Stateless implementation; mirrors `BaseALFHook.supportsInterface`. Subclasses that
implement additional interfaces should override and OR-in their own selectors.


```solidity
function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool);
```

### isLive

Whether this hook is currently live and accepting swaps.

Always reports live; hook-level liveness is per-pool via `livePools[poolId]`.
Routers call this to reject offline hooks; this hook is always reachable, but
individual pools may pause via {DualPoolHook.setPoolLive}.


```solidity
function isLive() external pure override returns (bool);
```

### getIndicativeQuote

Get an indicative quote for routing purposes.

DualPool's deployable single-contract build does not include the heavy virtual
multi-range tick-walking quoter. Returning 0 is the IALFHook unsupported-quote path.


```solidity
function getIndicativeQuote(PoolKey calldata, bool, int256, bytes calldata)
    external
    view
    virtual
    override
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`PoolKey`||
|`<none>`|`bool`||
|`<none>`|`int256`||
|`<none>`|`bytes`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|outputAmount The indicative number of output tokens. For exact input swaps, this is the expected output. For exact output swaps, this is the required input.|


### getReserves

Total reserves managed by the hook (true TVL).

Should include ALL assets under management: ERC-20 balances, ERC-6909 claims,
vault deposits, rehypothecated assets, etc. Returns (0, 0) for hooks that do
not manage off-pool reserves.


```solidity
function getReserves(PoolKey calldata) external view virtual override returns (uint256, uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`PoolKey`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|token0 Total amount of token0 reserves.|
|`<none>`|`uint256`|token1 Total amount of token1 reserves.|


### getEffectiveLiquidity

Assets available for immediate swapping.

Returns liquidity that can be accessed right now for trading. Always <= getReserves().
May differ from getReserves() if some liquidity is not available for deployment (e.g., from a vault with too much utilization).
Returns (0, 0) for hooks that do not manage off-pool reserves.


```solidity
function getEffectiveLiquidity(PoolKey calldata) external view virtual override returns (uint256, uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`PoolKey`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|token0 Immediately swappable token0 liquidity.|
|`<none>`|`uint256`|token1 Immediately swappable token1 liquidity.|


### swapToPrice

Simulate a swap up to a target price, returning both input consumed and output received.

Same unsupported-simulation policy as `getIndicativeQuote`.


```solidity
function swapToPrice(PoolKey calldata, bool, int256, uint160, bytes calldata)
    external
    view
    virtual
    override
    returns (uint256, uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`PoolKey`||
|`<none>`|`bool`||
|`<none>`|`int256`||
|`<none>`|`uint160`||
|`<none>`|`bytes`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|amountIn Total input consumed (including fees).|
|`<none>`|`uint256`|amountOut Total output received.|


### _pay

Abstract function for contracts to implement paying tokens to the poolManager

Settles a hook-owed delta by transferring `amount` of `token` directly to the
PoolManager. The `payer` argument is unused because settlement is always from
the hook's own balance.


```solidity
function _pay(Currency token, address, uint256 amount) internal override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`Currency`|The token to settle. This is known not to be the native currency|
|`<none>`|`address`||
|`amount`|`uint256`|The number of tokens to send|


## Events
### PoolLivenessUpdated
Emitted whenever a pool's liveness flag changes.


```solidity
event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose liveness changed.|
|`isLive`|`bool`|The new liveness state.|

## Errors
### InvalidTickRange
A bucket's tick range is malformed (lower >= upper, out of `TickMath` range, or
not aligned to the pool's tickSpacing).


```solidity
error InvalidTickRange();
```

### DirectInitializeBlocked
Direct `poolManager.initialize` for any DualPool-hooked pool is rejected;
callers MUST go through the subclass's guarded `initializePool` entry point so
pricing, distribution, and vault config are validated before PM init runs.


```solidity
error DirectInitializeBlocked();
```

