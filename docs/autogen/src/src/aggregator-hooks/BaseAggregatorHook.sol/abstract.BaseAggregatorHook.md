# BaseAggregatorHook
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/269a4bc7c24c99a9bf6408262df37a462d8a2b9c/src/aggregator-hooks/BaseAggregatorHook.sol)

**Inherits:**
[IAggregatorHook](/src/aggregator-hooks/interfaces/IAggregatorHook.sol/interface.IAggregatorHook.md), [ProtocolFees](/src/aggregator-hooks/ProtocolFees.sol/abstract.ProtocolFees.md), [BaseHook](/src/base/BaseHook.sol/abstract.BaseHook.md), DeltaResolver

**Title:**
BaseAggregatorHook

Abstract contract for implementing aggregator hooks in Uniswap V4

Implements the IAggregatorHook interface, leverages the ProtocolFees contract, and extends the BaseHook contract


## State Variables
### aggregatorHookVersion
The publicly displayed version of the aggregator hook.

Although this should never change after construction, strings cannot be labelled immutable.


```solidity
string public aggregatorHookVersion
```


## Functions
### constructor

Initializes the hook with required dependencies


```solidity
constructor(IPoolManager _manager, string memory _aggregatorHookVersion) BaseHook(_manager);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_manager`|`IPoolManager`|The Uniswap V4 PoolManager contract|
|`_aggregatorHookVersion`|`string`||


### pollTokenJar

Queries the token jar from the pool manager and emits an event if it is updated

This function should not need to be called externally except in the case of the tokenJar address changing
after the protocol fee has been set


```solidity
function pollTokenJar() public virtual override returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The token jar address|


### pseudoTotalValueLocked

Returns the pseudo TVL: the amount of the UniswapV4 pool's tokens locked in the aggregated pool


```solidity
function pseudoTotalValueLocked(PoolId poolId) external view virtual returns (uint256 amount0, uint256 amount1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool ID of the UniswapV4 pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|The amount of token0 in the aggregated pool|
|`amount1`|`uint256`|The amount of token1 in the aggregated pool|


### quote

Quotes amount of unspecified side for a given amount of specified side

This function is meant to be called as a view function even though it is not one. This is because the swap
might be simulated but not finalized. Applies protocol fee on top of the raw quote from the underlying liquidity source


```solidity
function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    external
    payable
    returns (uint256 amountUnspecified);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`zeroToOne`|`bool`|Whether the swap is from token0 to token1 or from token1 to token0|
|`amountSpecified`|`int256`|The amount of tokens in or out (negative for exact-in, positive for exact-out)|
|`poolId`|`PoolId`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountUnspecified`|`uint256`|amount of unspecified side (always positive to adhere to practices by other quote functions)|


### getHookPermissions

Returns a struct of permissions to signal which hook functions are to be implemented

Used at deployment to validate the address correctly represents the expected permissions


```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`permissions`|`Hooks.Permissions`|Permissions struct|


### _conductSwap

Abstract function for contracts to implement conducting the swap on the aggregated liquidity source

To settle the swap inside of the _conductSwap function, you must follow the 'sync, send,
settle' pattern and set hasSettled to true


```solidity
function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
    internal
    virtual
    returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`settleCurrency`|`Currency`|The currency to be settled on the V4 PoolManager (swapper's output currency)|
|`takeCurrency`|`Currency`|The currency to be taken from the V4 PoolManager (swapper's input currency)|
|`params`|`SwapParams`|The swap parameters|
|`poolId`|`PoolId`|The V4 Pool ID|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountSettle`|`uint256`|The amount of the currency being settled (swapper's output amount)|
|`amountTake`|`uint256`|The amount of the currency being taken (swapper's input amount)|
|`hasSettled`|`bool`|Whether the swap has been settled inside of the _conductSwap function|


### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees


```solidity
function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    internal
    virtual
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


### _beforeInitialize


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4);
```

### _beforeAddLiquidity


```solidity
function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
    internal
    override
    returns (bytes4);
```

### _beforeSwap


```solidity
function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24);
```

### _processAmounts


```solidity
function _processAmounts(uint256 amountIn, uint256 amountOut, bool exactInput)
    internal
    pure
    returns (int128 unspecifiedDelta);
```

### _internalSettle


```solidity
function _internalSettle(PoolKey calldata key, SwapParams calldata params)
    internal
    returns (uint256 amountIn, uint256 amountOut);
```

### _pay


```solidity
function _pay(Currency token, address payer, uint256 amount) internal override;
```

### receive

Allows the contract to receive ETH for native currency swaps

Required for handling native ETH transfers during swap operations


```solidity
receive() external payable;
```

