# BaseALFHook
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/base/BaseALFHook.sol)

**Inherits:**
[BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md), DeltaResolver, [IALFHook](/src/alf/interfaces/IALFHook.sol/interface.IALFHook.md)

**Title:**
BaseALFHook

**Author:**
Uniswap Labs

Abstract base contract for ALF hooks. Provides hookData resolution, settlement
helpers, and the IALFHook interface. Quoters extend this and implement _price()
with their pricing logic.

Follows the same BaseHook + DeltaResolver dual-inheritance pattern as BaseTokenWrapperHook.

**Note:**
security-contact: security@uniswap.org


## Constants
### _maxGas
Gas budget declared for `getIndicativeQuote` staticcalls. Returned by `maxGas()`.


```solidity
uint32 private immutable _maxGas
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, uint32 maxGas_) BaseHook(_poolManager);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolManager`|`IPoolManager`|The Uniswap v4 PoolManager.|
|`maxGas_`|`uint32`|     Gas budget declared for `getIndicativeQuote` staticcalls.|


### maxGas

The declared maximum gas for getIndicativeQuote execution.

Callers use this to set gas limits on staticcall invocations.


```solidity
function maxGas() external view override returns (uint32);
```

### supportsInterface

ERC-165 advertisement for the interfaces this contract implements.

Stateless implementation (no inherited `ERC165` storage). Advertises `IALFHook`,
`IHooks` (implemented via `BaseHook`), and `IERC165`. Subclasses that implement
additional interfaces should override this and OR-in their own selectors.


```solidity
function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool);
```

### getIndicativeQuote

Get an indicative quote for routing purposes.

MUST be a view function. Callers invoke via staticcall.


```solidity
function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
    external
    view
    virtual
    override
    returns (uint256 outputAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`key`|`PoolKey`|The pool key for this quoter's pool.|
|`zeroForOne`|`bool`|The swap direction.|
|`amountSpecified`|`int256`|The swap amount. Negative = exact input.|
|`hookData`|`bytes`|ABI-encoded ALFHookData struct, or empty bytes.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`outputAmount`|`uint256`|The indicative number of output tokens. For exact input swaps, this is the expected output. For exact output swaps, this is the required input.|


### isLive

Whether this hook is currently live and accepting swaps.

Hooks SHOULD return true if the current curve is not stale.


```solidity
function isLive() external view virtual override returns (bool);
```

### getReserves

Total reserves managed by the hook (true TVL).

Should include all assets under management: ERC-20 balances, ERC-6909 claims,
vault deposits, rehypothecated assets, etc. Returns (0, 0) for hooks that do
not manage off-pool reserves. This is the gross economic stake and MAY exceed what is
immediately withdrawable (see {getEffectiveLiquidity}).


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
|`<none>`|`uint256`|token0 Total amount of token0 reserves, in token0's native decimals.|
|`<none>`|`uint256`|token1 Total amount of token1 reserves, in token1's native decimals.|


### getEffectiveLiquidity

Assets available for immediate swapping.

Returns liquidity that can be accessed right now for trading. Always <= getReserves().
May differ from getReserves() if some liquidity is not available for deployment (e.g., from a vault with too much utilization).
Returns (0, 0) for hooks that do not manage off-pool reserves.
Implementations SHOULD report fee-net, immediately-deliverable reserves: consumers (such as
the ALFMultiplexer's reserve-bounded strict-tolerance baseline) treat the returned value as
the deliverable output cap, a bound that is only sound when reserves are net of the fee a swap
pays. An over-reported (gross) value weakens those consumers' deliverability bounds, which is
part of the trusted-targets assumption such consumers make.


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
|`<none>`|`uint256`|token0 Immediately swappable token0 liquidity, in token0's native decimals.|
|`<none>`|`uint256`|token1 Immediately swappable token1 liquidity, in token1's native decimals.|


### swapToPrice

Simulate a swap up to a target price, returning both input consumed and output received.

Used by the multiplexer and router for split fill planning. The swap terminates
when the target price is reached or the specified amount is exhausted, whichever
comes first. Returns (0, 0) for hooks that do not support price-bounded simulation.


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


### _resolveHookData

Decode ALFHookData and resolve attestation. The base implementation does not
verify attestations; subclasses that want attestation support override
`_resolveAttestation` with their own verification logic.


```solidity
function _resolveHookData(bytes calldata hookData) internal view returns (bool isAttested, address attester);
```

### _resolveAttestation

Resolve attestation from raw bytes. Default returns (false, address(0)).
Subclasses can override to verify attestationData against their own signer.


```solidity
function _resolveAttestation(bytes memory) internal view virtual returns (bool isAttested, address attester);
```

### _price

Indicative pricing backing the default [getIndicativeQuote](/src/alf/base/BaseALFHook.sol/abstract.BaseALFHook.md#getindicativequote). Defaults to 0: the
IALFHook "cannot price this swap" path. Quoter subclasses override with their curve
(e.g. `SpreadQuoterBase` simulates against the pool's static fee). Hooks that price
against bespoke liquidity (e.g. `DualPoolHook`) override `getIndicativeQuote`
directly instead, leaving this dormant.


```solidity
function _price(PoolKey calldata, bool, int256, bool, address) internal view virtual returns (uint256);
```

### _pay

Abstract function for contracts to implement paying tokens to the poolManager

Pays the PoolManager using v4's `Currency.transfer` rather than OZ `SafeERC20`, by
design: this matches v4 periphery's `DeltaResolver` convention (the destination is the
trusted PoolManager during an unlock, and `Currency.transfer` handles native ETH and
the no-return-value ERC-20 quirk in the same path).


```solidity
function _pay(Currency token, address, uint256 amount) internal virtual override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`Currency`|The token to settle. This is known not to be the native currency|
|`<none>`|`address`||
|`amount`|`uint256`|The number of tokens to send|


