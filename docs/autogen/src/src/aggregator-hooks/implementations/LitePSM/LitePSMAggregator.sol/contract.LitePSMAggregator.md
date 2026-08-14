# LitePSMAggregator
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/5487b2c1a8e5d06a78754ce93a8634b8dd91d659/src/aggregator-hooks/implementations/LitePSM/LitePSMAggregator.sol)

**Inherits:**
[BaseAggregatorHook](/src/aggregator-hooks/BaseAggregatorHook.sol/abstract.BaseAggregatorHook.md)

**Title:**
LitePSMAggregator

Singleton Uniswap V4 hook that routes gem ↔ stable swaps through a MakerDAO LitePSM

Compatible with both LitePSMWrapper (USDS/USDC) and the underlying LitePSM-DAI-USDC.
The gem token (USDC) is resolved from litePSM.gem() at construction; the counterpart
stable (USDS or DAI) is passed in by the deployer.
Because the PSM uses 6-decimal gem and 18-decimal stable, all amount conversions
use the immutable to18ConversionFactor read from the PSM at construction time.
tin  = fee on gem→stable (sellGem); tout = fee on stable→gem (buyGem). Both in WAD units.


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


### stableToken
The stable token address (USDS or DAI) — supplied by the deployer


```solidity
address public immutable stableToken
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
Canonical pool per token pair — enforces one pool per gem/stable pair


```solidity
mapping(bytes32 => PoolId) private _canonicalPoolByPair
```


## Functions
### constructor


```solidity
constructor(IPoolManager _manager, ILitePSM _litePSM, address _stableToken)
    BaseAggregatorHook(_manager, "LitePSMAggregator v1.0");
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_manager`|`IPoolManager`|The Uniswap V4 PoolManager contract|
|`_litePSM`|`ILitePSM`|The LitePSM or LitePSMWrapper contract|
|`_stableToken`|`address`|The stable token address — USDS for LitePSMWrapper, DAI for LitePSM-DAI-USDC (18 decimals)|


### pseudoTotalValueLocked


```solidity
function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1);
```

### protocolFeeFlags


```solidity
function protocolFeeFlags() external pure override returns (uint256);
```

### _rawQuote

Returns the raw quote from the underlying liquidity source without protocol fees

Quotes without fees; BaseAggregatorHook.quote() applies protocol fees on top.
Reads tin/tout fresh each call since governance can change them.
Capacity limits are applied to prevent quoting liquidity that the PSM cannot fill:
- sellGem (gem→stable): capped at `buf / to18ConversionFactor` (gem units). This uses
`buf` as a proxy for the true cap of `min(buf, lineRoom) / to18`, since `lineRoom`
is only accessible via the Vat and is not exposed by the LitePSMWrapper. In practice
buf is kept below the debt ceiling, so this proxy is conservative and accurate.
- buyGem (stable→gem): capped at the gem balance held in `pocket()`. This is exact.
When an amount exceeds available capacity:
- Exact-in: reverts with ExceedsCapacity (the full input cannot be processed)
- Exact-out: reverts with ExceedsCapacity (the desired output cannot be sourced)


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

### ExceedsCapacity

```solidity
error ExceedsCapacity();
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

