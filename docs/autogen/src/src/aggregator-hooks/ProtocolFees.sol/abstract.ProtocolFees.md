# ProtocolFees
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/0d898f379fdd8fbc42644ea0b0c8de37213bdae1/src/aggregator-hooks/ProtocolFees.sol)


## State Variables
### tokenJar

```solidity
address public tokenJar
```


## Functions
### pollTokenJar

Queries the token jar from the pool manager and emits an event if it is updated

This function should not need to be called externally except in the case of the tokenJar address changing
after the protocol fee has been set


```solidity
function pollTokenJar() public virtual returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The token jar address|


### _applyProtocolFee


```solidity
function _applyProtocolFee(
    IPoolManager poolManager,
    PoolKey calldata key,
    SwapParams calldata params,
    int128 unspecifiedDelta
) internal returns (int128);
```

### _calculateProtocolFeeAmount


```solidity
function _calculateProtocolFeeAmount(uint24 protocolFee, bool isExactInput, uint256 amountUnspecified)
    internal
    pure
    returns (uint256);
```

### _getProtocolFee


```solidity
function _getProtocolFee(IPoolManager poolManager, bool zeroToOne, PoolId poolId)
    internal
    view
    returns (uint24 protocolFee);
```

### _getTokenJar


```solidity
function _getTokenJar(IPoolManager poolManager) internal view returns (address currentJar);
```

## Events
### ProtocolFeesCollected

```solidity
event ProtocolFeesCollected(address indexed recipient, Currency indexed currency, uint256 amount);
```

### TokenJarUpdated

```solidity
event TokenJarUpdated(address indexed tokenJar);
```

