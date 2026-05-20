# ITesseraPool
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/03c6c317e620e2eb32675653ad26bf7faacc5605/src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraPool.sol)

**Title:**
ITesseraPool

Per-pair Tessera pool view interface


## Functions
### baseToken

The base token of this Tessera pair (the non-numeraire side).


```solidity
function baseToken() external view returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The base token address.|


### quoteToken

The quote token of this Tessera pair (the numeraire side, typically USDC).


```solidity
function quoteToken() external view returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The quote token address.|


### baseTokenDecimal

Decimals of the base token, cached by the pool at registration.


```solidity
function baseTokenDecimal() external view returns (uint8);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint8`|The base token's `decimals()` value.|


### quoteTokenDecimal

Decimals of the quote token, cached by the pool at registration.


```solidity
function quoteTokenDecimal() external view returns (uint8);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint8`|The quote token's `decimals()` value.|


### tradingEnabled

Per-pool trading kill-switch maintained by the Tessera operator.


```solidity
function tradingEnabled() external view returns (bool);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if the pool is currently accepting swaps.|


