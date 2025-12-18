# BaseGuidestarHook
[Git Source](https://github.com/Uniswap/v4-hooks/blob/af82e7dad988a6dbd52b8a924edb99094802d853/src/guidestar/BaseGuidestarHook.sol)

**Inherits:**
Ownable


## State Variables
### poolManager

```solidity
IPoolManager public immutable poolManager
```


### gateway

```solidity
address public immutable gateway
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, address _initialOwner, address _gateway) ;
```

### onlyByGateway


```solidity
modifier onlyByGateway() ;
```

## Errors
### NotGateway

```solidity
error NotGateway();
```

