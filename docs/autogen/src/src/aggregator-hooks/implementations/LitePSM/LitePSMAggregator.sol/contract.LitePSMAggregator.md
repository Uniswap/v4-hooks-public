# LitePSMAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/a4dd8463f7e31d29785c1d924a63dbe40a10ac05/src/aggregator-hooks/implementations/LitePSM/LitePSMAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md)

**Title:**
LitePSMAggregator

Singleton Uniswap V4 hook that routes USDC ↔ USDS swaps through MakerDAO's LitePSM

Supports pools containing exactly the PSM's gem (USDC) and USDS token pair.
Because the PSM uses 6-decimal USDC (gem) and 18-decimal USDS, all amount conversions
use the immutable to18ConversionFactor read from the PSM at construction time.
tin  = fee on USDC→USDS (sellGem); tout = fee on USDS→USDC (buyGem). Both in WAD units.


## State Variables
### WAD

```solidity
uint256 private constant WAD = 1e18
```


### litePSM
The LitePSM (or LitePSMWrapper) contract


```solidity
ILitePSM public immutable litePSM
```


### gemToken
The USDC (gem) token address — pulled from litePSM.gem() at construction


```solidity
address public immutable gemToken
```


### usdsToken
The USDS token address — supplied by the deployer


```solidity
address public immutable usdsToken
```


### to18ConversionFactor
Decimal conversion factor from gem to 18 decimals (10^12 for USDC)

Cached from litePSM.to18ConversionFactor() to avoid repeated SLOADs


```solidity
uint256 public immutable to18ConversionFactor
```


### poolIdToTokens
Maps Uniswap V4 pool IDs to their token addresses


```solidity
mapping(PoolId => PoolTokens) public poolIdToTokens
```


### _canonicalPoolByPair
Canonical pool per token pair — enforces one pool per USDC/USDS pair


```solidity
mapping(bytes32 => PoolId) private _canonicalPoolByPair
```


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, ILitePSM _litePSM, address _usdsToken)
    BaseAggregatorHook(_manager, "LitePSMAggregator v1.0");
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_manager`|`IPoolManager`|The Uniswap V4 PoolManager contract|
|`_litePSM`|`ILitePSM`|The LitePSM or LitePSMWrapper contract|
|`_usdsToken`|`address`|The USDS token address (18 decimals)|


### pseudoTotalValueLocked


```solidity
function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1);
```

### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees

Quotes without fees; BaseAggregatorHook.quote() applies protocol fees on top.
Reads tin/tout fresh each call since governance can change them.


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


### _beforeInitialize


```solidity
function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4);
```

### _conductSwap


```solidity
function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
    internal
    override
    returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);
```

### _canonicalPairKey


```solidity
function _canonicalPairKey(address token0, address token1) private pure returns (bytes32);
```

## Errors
### TokensNotSupported

```solidity
error TokensNotSupported(address token0, address token1);
```

### PairAlreadyHasCanonicalPool

```solidity
error PairAlreadyHasCanonicalPool(PoolId existingPoolId, address token0, address token1);
```

## Structs
### PoolTokens
Token addresses stored per registered V4 pool


```solidity
struct PoolTokens {
    address token0;
    address token1;
}
```

