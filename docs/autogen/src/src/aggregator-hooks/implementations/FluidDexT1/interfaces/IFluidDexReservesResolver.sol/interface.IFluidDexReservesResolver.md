# IFluidDexReservesResolver
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/1f52c3f85ae2e6c0f55bd2f364a64854ec0b34bc/src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexReservesResolver.sol)

**Title:**
IFluidDexReservesResolver

Interface for the Fluid DEX T1 reserves resolver


## Functions
### getPoolReserves

Get pool data with reserves for a specific DEX

Matches Fluid's FluidDexReservesResolver.getPoolReserves


```solidity
function getPoolReserves(address pool_) external view returns (PoolWithReserves memory poolReserves_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`pool_`|`address`|The address of the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`poolReserves_`|`PoolWithReserves`|The pool data including reserves|


## Structs
### DexLimits

```solidity
struct DexLimits {
    TokenLimit withdrawableToken0;
    TokenLimit withdrawableToken1;
    TokenLimit borrowableToken0;
    TokenLimit borrowableToken1;
}
```

### TokenLimit

```solidity
struct TokenLimit {
    uint256 available;
    uint256 expandsTo;
    uint256 expandDuration;
}
```

### PoolWithReserves

```solidity
struct PoolWithReserves {
    address pool;
    address token0;
    address token1;
    uint256 fee;
    uint256 centerPrice;
    IFluidDexT1.CollateralReserves collateralReserves;
    IFluidDexT1.DebtReserves debtReserves;
    DexLimits limits;
}
```

