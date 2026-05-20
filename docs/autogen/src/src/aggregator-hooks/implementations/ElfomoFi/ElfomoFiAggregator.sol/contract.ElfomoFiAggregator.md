# ElfomoFiAggregator
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/03c6c317e620e2eb32675653ad26bf7faacc5605/src/aggregator-hooks/implementations/ElfomoFi/ElfomoFiAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md), [IElfomoSwapCallback](/src/aggregator-hooks/implementations/ElfomoFi/interfaces/IElfomoSwapCallback.sol/interface.IElfomoSwapCallback.md), Ownable, Tstorish

**Title:**
ElfomoFiAggregator

Singleton Uniswap V4 hook that aggregates liquidity from the ElfomoFi PropAMM router

One canonical V4 pool per token pair. Uses the callback variant of ElfomoFi's swap logic
(`swapWithCallback`) so no standing approval is parked on the router.
Trust model: ElfomoFi's `pricing` is immutable on the deployed router and `vault` is
immutable; both are honest-counterparty trust anchors at deploy time. The hook enforces
that the engine reports the EXACT amount the user specified for the side they specified;
slippage on the unspecified side is the integrator's responsibility (use V4's Universal
Router or another slippage-aware caller).
Quote nuance: `IElfomoFi.getAmountOut`/`getAmountIn` hard-code `partnerId = 0` on the
deployed router, while `swapWithCallback` uses our configured `partnerId`. While
`partnerId == 0` the public `quote()` matches execution exactly. If a non-zero partner
ID is set in the future, integrators consuming `quote()` may observe drift if ElfomoFi's
pricing oracle prices partners differently.

**Note:**
security-contact: security@uniswap.org


## State Variables
### elfomoFi
The ElfomoFi PropAMM router (same address on Base and BSC)


```solidity
IElfomoFi public immutable elfomoFi
```


### elfomoFiVault
The ElfomoFi vault address that holds the protocol's inventory

ElfomoFi's `vault` is immutable on the deployed router; we accept it as a constructor
argument because the deployed router does not expose a getter.


```solidity
address public immutable elfomoFiVault
```


### partnerId
Partner identifier used for rebate tracking on every swap

Defaults to 0 ("not used") until Uniswap is assigned a partner ID


```solidity
uint256 public immutable partnerId
```


### poolIdToTokens
Maps Uniswap V4 pool IDs to their token addresses


```solidity
mapping(PoolId => PoolTokens) public poolIdToTokens
```


### _canonicalPoolByPair
Canonical V4 pool per ordered token pair; enforces one canonical V4 pool per pair


```solidity
mapping(bytes32 => PoolId) private _canonicalPoolByPair
```


### INFLIGHT_SLOT
Slot that holds 1 while a swap from this hook is being processed by ElfomoFi.
Backed by TSTORE on chains with EIP-1153 support, SSTORE elsewhere (via Tstorish).
Value: `uint256(keccak256("aggregator-hooks.elfomo-fi.inflight")) - 1`.


```solidity
uint256 private constant INFLIGHT_SLOT = 0xbf35faecc380af431437a321ef8ef6b194285d57e89943775f424ab582ab8714
```


### CALLBACK_AMOUNT_IN_SLOT
Slot that captures the amount of `fromToken` ElfomoFi reports in the callback.
Value: `uint256(keccak256("aggregator-hooks.elfomo-fi.callback-amount-in")) - 1`.


```solidity
uint256 private constant CALLBACK_AMOUNT_IN_SLOT =
    0xba9cd5fa12de9303ee2a6860411fa6a29fe681192d5c194de5fb3ec2a4f5f0ac
```


### CALLBACK_AMOUNT_OUT_SLOT
Slot that captures the amount of `toToken` ElfomoFi reports in the callback.
Value: `uint256(keccak256("aggregator-hooks.elfomo-fi.callback-amount-out")) - 1`.


```solidity
uint256 private constant CALLBACK_AMOUNT_OUT_SLOT =
    0x0c3c2eaa0f36d92d1462d72fc6eb299bf0f62fd769692de3ac027ff56932f068
```


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, IElfomoFi _elfomoFi, address _elfomoFiVault, uint256 _partnerId, address _owner)
    BaseAggregatorHook(_manager, "ElfomoFiAggregator v1.0")
    Ownable(_owner);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_manager`|`IPoolManager`|The Uniswap V4 PoolManager contract.|
|`_elfomoFi`|`IElfomoFi`|The ElfomoFi PropAMM router (same address on Base and BSC at deploy time).|
|`_elfomoFiVault`|`address`|The ElfomoFi vault address that holds protocol inventory.|
|`_partnerId`|`uint256`|Partner identifier used on every `swapWithCallback`. Use `0` until Uniswap is assigned an official partner ID for ElfomoFi rebates.|
|`_owner`|`address`|The address that may deregister squatted canonical pairs.|


### elfomoSwapCallback

Called by ElfomoFi after the output side of a swap has been delivered to `receiver`

Called by ElfomoFi during `swapWithCallback`. Must transfer `uint256(fromTokenDelta)`
of the input token to the ElfomoFi contract before returning.


```solidity
function elfomoSwapCallback(int256 fromTokenDelta, int256 toTokenDelta, bytes calldata data) external override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`fromTokenDelta`|`int256`|Amount of `fromToken` the callee owes to the ElfomoFi contract (positive)|
|`toTokenDelta`|`int256`|Amount of `toToken` that was sent to the receiver (negative)|
|`data`|`bytes`|The opaque bytes passed into `ElfomoFi.swapWithCallback`|


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

Reads `balanceOf(elfomoFiVault)` for both tokens (ElfomoFi's vault holds the protocol's
live inventory). Reading the router itself would return ~zero in steady state.


```solidity
function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1);
```

### deregisterPair

Free the canonical pair slot for a pool that was squatted with junk parameters.

`_beforeInitialize` is permissionless (so anyone can mine + initialize a hook address),
which means a griefer can front-run the team's intended `initialize()` with poison
fee/tickSpacing/sqrtPriceX96 and permanently occupy the canonical slot. This function
gives the owner an evict path. It only clears the local mapping — the V4 pool itself
is unaffected and the squatter retains whatever they already initialized.


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

Rejects native ETH pools, probes the pricing oracle in BOTH directions with one whole
token of `token0` and `token1` respectively to confirm bidirectional support, enforces
one canonical V4 pool per token pair, and registers token addresses for the pool id.
A pair that only quotes in one direction is rejected (would otherwise leave half the V4
pool reverting on every swap).


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

### _callElfomoFi

Extracted to avoid stack-too-deep in `_conductSwap`


```solidity
function _callElfomoFi(Currency takeCurrency, Currency settleCurrency, int256 v4AmountSpecified) private;
```

### _probePair

Probe ElfomoFi's pricing oracle for support of (fromToken -> toToken). Reverts unless
the oracle returns a non-zero quote for one whole `fromToken`.


```solidity
function _probePair(address fromToken, address toToken) private view;
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
|`value`|`bool`|`true` while a swap from this hook is in flight on ElfomoFi.|


### _isInflight

Reads the inflight sentinel via Tstorish.


```solidity
function _isInflight() private view returns (bool value);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`value`|`bool`|`true` if a swap from this hook is currently in flight on ElfomoFi.|


### _writeCallbackAmounts

Captures the amounts ElfomoFi reported in the most recent callback.


```solidity
function _writeCallbackAmounts(uint256 amountIn, uint256 amountOut) private;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of `takeCurrency` (input) ElfomoFi consumed, in token base units.|
|`amountOut`|`uint256`|Amount of `settleCurrency` (output) ElfomoFi delivered to PoolManager, in token base units.|


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
Thrown when `elfomoSwapCallback` is invoked by an address other than `elfomoFi`.


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
Thrown when ElfomoFi's pricing oracle reverts or returns zero for either direction.


```solidity
error PairNotSupported(address token0, address token1);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token0`|`address`|The pair's lower-address token.|
|`token1`|`address`|The pair's higher-address token.|

### ZeroAddress
Thrown when a constructor argument is the zero address.


```solidity
error ZeroAddress();
```

### InvalidCallbackAmounts
Thrown when ElfomoFi reports out-of-spec callback parameter signs
(expected: `fromTokenDelta > 0`, `toTokenDelta < 0`).


```solidity
error InvalidCallbackAmounts(int256 fromTokenDelta, int256 toTokenDelta);
```

### EngineSpecifiedAmountMismatch
Thrown when ElfomoFi's reported amount on the specified side disagrees with what the
V4 swap asked for. Catches engine bugs without depending on integrator slippage.


```solidity
error EngineSpecifiedAmountMismatch(uint256 requested, uint256 reported);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`requested`|`uint256`|The absolute amount the V4 swap specified.|
|`reported`|`uint256`|The amount ElfomoFi reported for the specified side.|

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
Token pair info for each registered pool


```solidity
struct PoolTokens {
    address token0;
    address token1;
}
```

