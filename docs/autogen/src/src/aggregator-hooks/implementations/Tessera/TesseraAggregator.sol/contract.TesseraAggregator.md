# TesseraAggregator
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/03c6c317e620e2eb32675653ad26bf7faacc5605/src/aggregator-hooks/implementations/Tessera/TesseraAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md), [ITesseraSwapCallback](/src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraSwapCallback.sol/interface.ITesseraSwapCallback.md), Ownable, Tstorish

**Title:**
TesseraAggregator

Singleton Uniswap V4 hook that aggregates liquidity from the Tessera V EVM PropAMM

One canonical V4 pool per token pair. Uses the callback variant of Tessera's swap logic
(`tesseraSwapWithCallback`) so no standing approval is parked on the router.
Counterparty trust model (IMPORTANT):
- `tesseraEngine` and `tesseraTreasury` are storage variables on the deployed `TesseraSwap`
contract, mutable by a single `tesseraOwner` EOA with no timelock. The engine is the
sole authority on the `(amountIn, amountOut)` pair reported to this hook's callback.
- The hook defends against known possible edge cases, but not against the operator acting
maliciously. Tessera reports the amount the user specified for the side they specified.
Integrators must therefore enforce slippage on the unspecified side (Universal Router
and similar swap-routers do this). Direct `PoolManager.swap` callers without slippage
protection are exposed to whatever Tessera reports for the unspecified side.
- `tradingEnabled()` is checked only at pool registration. If Tessera operators disable
a registered pool, swaps will revert opaquely inside Tessera's code; the owner of this
hook can call `deregisterPair` to free the canonical slot for a fresh registration. The
owner can also evict a squatter that front-ran the team's intended `initialize()` with
poison `fee`/`tickSpacing`/`sqrtPriceX96` parameters.

**Note:**
security-contact: security@uniswap.org


## State Variables
### tesseraSwap
The TesseraSwap router (same address on Base and BSC)


```solidity
ITesseraSwap public immutable tesseraSwap
```


### tesseraManager
The Tessera pool registry (same address on Base and BSC)


```solidity
ITesseraManager public immutable tesseraManager
```


### tesseraTreasury
The Tessera treasury address that holds the protocol's inventory

`tesseraTreasury` is a private storage variable on the deployed `TesseraSwap`. We accept
it here as a constructor argument because the deployed router does not expose a getter.
Note that the treasury is owner-mutable on `TesseraSwap`; if it changes, this hook's
`pseudoTotalValueLocked` reading goes stale until the hook is redeployed.


```solidity
address public immutable tesseraTreasury
```


### poolIdToTokens
Maps Uniswap V4 pool IDs to their token addresses and the underlying Tessera pool


```solidity
mapping(PoolId => PoolTokens) public poolIdToTokens
```


### _canonicalPoolByPair
Canonical V4 pool per ordered token pair (Tempo pattern); enforces one canonical V4 pool per pair


```solidity
mapping(bytes32 => PoolId) private _canonicalPoolByPair
```


### INFLIGHT_SLOT
Slot that holds 1 while a swap from this hook is being processed by TesseraSwap.
Backed by TSTORE on chains with EIP-1153 support, SSTORE elsewhere (via Tstorish).
Value: `uint256(keccak256("aggregator-hooks.tessera.inflight")) - 1`.


```solidity
uint256 private constant INFLIGHT_SLOT = 0x11a0603b55240a854fd60675cd448f7099007c1401b0c576c7adaf6e4455a553
```


### CALLBACK_AMOUNT_IN_SLOT
Slot that captures the input amount TesseraSwap reports in the callback.
Value: `uint256(keccak256("aggregator-hooks.tessera.callback-amount-in")) - 1`.


```solidity
uint256 private constant CALLBACK_AMOUNT_IN_SLOT =
    0xdb305eccc6a8a82989ca68cc0fc484c898db8ebe32aeda1251ea1898bada2364
```


### CALLBACK_AMOUNT_OUT_SLOT
Slot that captures the output amount TesseraSwap reports in the callback.
Value: `uint256(keccak256("aggregator-hooks.tessera.callback-amount-out")) - 1`.


```solidity
uint256 private constant CALLBACK_AMOUNT_OUT_SLOT =
    0xf2c0893ae0a70fd8a5cc13e7f46d2b6cf9ff1f1fd3fcfd40c23a292ae5f5ed3e
```


## Functions
### constructor


```solidity
constructor(
    IPoolManager _manager,
    ITesseraSwap _tesseraSwap,
    ITesseraManager _tesseraManager,
    address _tesseraTreasury,
    address _owner
) BaseAggregatorHook(_manager, "TesseraAggregator v1.0") Ownable(_owner);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_manager`|`IPoolManager`|The Uniswap V4 PoolManager contract.|
|`_tesseraSwap`|`ITesseraSwap`|The TesseraSwap router (same address on Base and BSC at deploy time).|
|`_tesseraManager`|`ITesseraManager`|The Tessera pool registry (same address on Base and BSC at deploy time).|
|`_tesseraTreasury`|`address`|The Tessera treasury that holds inventory (used by `pseudoTotalValueLocked`).|
|`_owner`|`address`|The address that may deregister squatted canonical pairs.|


### tesseraSwapCallback

Called by TesseraSwap after the output side of a swap has been delivered to `recipient`

Called by TesseraSwap during `tesseraSwapWithCallback`. Must transfer `uint256(amountInDelta)`
of the input token to the TesseraSwap contract before returning.


```solidity
function tesseraSwapCallback(int256 amountInDelta, int256 amountOutDelta, bytes calldata data) external override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amountInDelta`|`int256`|Amount of `tokenIn` the callee owes to the TesseraSwap contract (positive)|
|`amountOutDelta`|`int256`|Amount of `tokenOut` that was sent to the recipient (negative)|
|`data`|`bytes`|The opaque bytes passed into `TesseraSwap.tesseraSwapWithCallback`|


### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees


```solidity
function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    internal
    view
    override
    returns (uint256 amountUnspecified);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`zeroToOne`|`bool`|Whether the swap is from token0 to token1|
|`amountSpecified`|`int256`|The amount specified (negative for exact-in, positive for exact-out)|
|`poolId`|`PoolId`|The pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountUnspecified`|`uint256`|The raw unspecified amount before protocol fee adjustment|


### pseudoTotalValueLocked

Reads `balanceOf(tesseraTreasury)` for both tokens (Tessera's treasury holds the
protocol's live inventory). The per-pool `tesseraPool` contract holds no inventory.


```solidity
function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1);
```

### deregisterPair

Free the canonical pair slot for a pool that was squatted with junk parameters or
for a pair whose underlying Tessera pool has been retired by the operator.

`_beforeInitialize` is permissionless, so anyone can front-run the team's intended
registration with poison fee/tickSpacing/sqrtPriceX96 and squat the canonical slot.
This function gives the owner an evict path. It only clears the local mapping — the V4
pool itself is unaffected and any squatter retains whatever they already initialized.


```solidity
function deregisterPair(PoolId poolId, address token0, address token1) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool id currently holding the canonical slot for the pair.|
|`token0`|`address`|The pair's lower-address token (pre-sorted is fine; the function re-sorts).|
|`token1`|`address`|The pair's higher-address token (pre-sorted is fine; the function re-sorts).|


### _beforeInitialize

Rejects native ETH pools, looks up the underlying Tessera pool through the manager
(rejecting multi-hop / unregistered pairs), enforces that the pool is currently trading,
enforces one canonical V4 pool per pair, and registers token addresses for the pool id.


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4);
```

### _conductSwap

Abstract function for contracts to implement conducting the swap on the aggregated liquidity source

To settle the swap inside of the _conductSwap function, you must follow the 'sync, send,
settle' pattern and set hasSettled to true


```solidity
function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
    internal
    override
    returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`settleCurrency`|`Currency`|The currency to be settled on the V4 PoolManager (swapper's output currency)|
|`takeCurrency`|`Currency`|The currency to be taken from the V4 PoolManager (swapper's input currency)|
|`params`|`SwapParams`|The swap parameters|
|`<none>`|`PoolId`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountSettle`|`uint256`|The amount of the currency being settled (swapper's output amount)|
|`amountTake`|`uint256`|The amount of the currency being taken (swapper's input amount)|
|`hasSettled`|`bool`|Whether the swap has been settled inside of the _conductSwap function|


### receive

Override `BaseAggregatorHook.receive()` to reject ETH outright. This hook never holds
native ETH (`_beforeInitialize` rejects native-currency pools), so any ETH that arrives
would be permanently stranded.


```solidity
receive() external payable override;
```

### _callTesseraSwap

Extracted to avoid stack-too-deep in `_conductSwap`


```solidity
function _callTesseraSwap(Currency takeCurrency, Currency settleCurrency, int256 v4AmountSpecified) private;
```

### _assertSpecifiedAmountMatch

Asserts that the engine's reported amount on the specified side matches what the
V4 swap requested. For exact-in (`v4AmountSpecified < 0`), the engine must consume
exactly `-v4AmountSpecified` of input. For exact-out (`> 0`), the engine must deliver
exactly `v4AmountSpecified` of output. The unspecified-side amount is unbounded here;
use V4's outer router for slippage protection.


```solidity
function _assertSpecifiedAmountMatch(int256 v4AmountSpecified, uint256 amountTake, uint256 amountSettle)
    private
    pure;
```

### _canonicalPairKey

Returns the canonical storage key for a token pair, order-independent.


```solidity
function _canonicalPairKey(address token0, address token1) private pure returns (bytes32);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token0`|`address`|One side of the pair (any ordering).|
|`token1`|`address`|The other side of the pair.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes32`|The canonical pair key, derived from the two addresses sorted ascending.|


### _setInflight

Writes the inflight sentinel via Tstorish (TSTORE if available, SSTORE fallback).


```solidity
function _setInflight(bool value) private;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`value`|`bool`|`true` while a swap from this hook is in flight on TesseraSwap.|


### _isInflight

Reads the inflight sentinel via Tstorish.


```solidity
function _isInflight() private view returns (bool value);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`value`|`bool`|`true` if a swap from this hook is currently in flight on TesseraSwap.|


### _writeCallbackAmounts

Captures the amounts TesseraSwap reported in the most recent callback.


```solidity
function _writeCallbackAmounts(uint256 amountIn, uint256 amountOut) private;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of `takeCurrency` (input) TesseraSwap consumed, in token base units.|
|`amountOut`|`uint256`|Amount of `settleCurrency` (output) TesseraSwap delivered to PoolManager, in token base units.|


### _readCallbackAmounts

Reads back the amounts captured by the last callback.


```solidity
function _readCallbackAmounts() private view returns (uint256 amountIn, uint256 amountOut);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of `takeCurrency` (input) consumed, in token base units.|
|`amountOut`|`uint256`|Amount of `settleCurrency` (output) delivered to PoolManager, in token base units.|


## Events
### PairDeregistered
Emitted when the owner deregisters a canonical pair, freeing it for a new pool


```solidity
event PairDeregistered(PoolId indexed poolId, address token0, address token1);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool id that was holding the canonical slot for the pair.|
|`token0`|`address`|The pair's lower-address token.|
|`token1`|`address`|The pair's higher-address token.|

## Errors
### UnauthorizedCallback
Thrown when `tesseraSwapCallback` is invoked by an address other than `tesseraSwap`.


```solidity
error UnauthorizedCallback();
```

### ProhibitedEntry
Thrown when the callback runs without the transient inflight flag set
(i.e. not invoked as part of an in-flight `_conductSwap`).


```solidity
error ProhibitedEntry();
```

### Reentrancy
Thrown when `_conductSwap` is re-entered while a prior swap is still in flight.


```solidity
error Reentrancy();
```

### NativeCurrencyNotSupported
Thrown when `_beforeInitialize` is called with `address(0)` as either currency.


```solidity
error NativeCurrencyNotSupported();
```

### PairAlreadyRegistered
Thrown when a token pair already has a canonical V4 pool registered with this hook.


```solidity
error PairAlreadyRegistered(PoolId existingPoolId, address token0, address token1);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`existingPoolId`|`PoolId`|The pool id of the previously-registered V4 pool for the pair.|
|`token0`|`address`|The pair's lower-address token.|
|`token1`|`address`|The pair's higher-address token.|

### PairNotSupported
Thrown when the Tessera manager has no direct pool registered for the given pair
(multi-hop pairs that would route through `baseRoutingAsset` are intentionally rejected).


```solidity
error PairNotSupported(address token0, address token1);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token0`|`address`|The pair's lower-address token.|
|`token1`|`address`|The pair's higher-address token.|

### PoolTradingDisabled
Thrown when the underlying Tessera pool exists but currently has trading disabled.


```solidity
error PoolTradingDisabled(address pool);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`pool`|`address`|The address of the underlying Tessera pool with `tradingEnabled == false`.|

### ZeroAddress
Thrown when a constructor argument is the zero address.


```solidity
error ZeroAddress();
```

### InvalidCallbackAmounts
Thrown when TesseraSwap reports out-of-spec callback parameter signs
(expected: `amountInDelta > 0`, `amountOutDelta < 0`).


```solidity
error InvalidCallbackAmounts(int256 amountInDelta, int256 amountOutDelta);
```

### EngineSpecifiedAmountMismatch
Thrown when the Tessera engine's reported amount on the specified side disagrees with
what the V4 swap asked for. Catches engine bugs without depending on integrator slippage.


```solidity
error EngineSpecifiedAmountMismatch(uint256 requested, uint256 reported);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`requested`|`uint256`|The absolute amount the V4 swap specified.|
|`reported`|`uint256`|The amount the engine reported for the specified side.|

### NoEthAccepted
Thrown when ETH is sent directly to the hook (no legitimate ETH path exists).


```solidity
error NoEthAccepted();
```

### NotCanonicalPool
Thrown when an attempted deregistration targets a pool id that isn't currently the
canonical pool for the given pair.


```solidity
error NotCanonicalPool(PoolId requested, PoolId canonical);
```

## Structs
### PoolTokens
Token pair info for each registered pool, plus the underlying Tessera pool address
used for `pseudoTotalValueLocked` lookups.


```solidity
struct PoolTokens {
    address token0;
    address token1;
    address tesseraPool;
}
```

