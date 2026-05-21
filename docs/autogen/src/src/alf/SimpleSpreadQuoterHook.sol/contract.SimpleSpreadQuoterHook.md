# SimpleSpreadQuoterHook
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/510f5fe7d91535158cac5795bb284c347ddb8126/src/alf/SimpleSpreadQuoterHook.sol)

**Inherits:**
[SpreadQuoterBase](/src/alf/base/SpreadQuoterBase.sol/abstract.SpreadQuoterBase.md)

**Title:**
SimpleSpreadQuoterHook

**Author:**
Uniswap Labs

Spread quoter with owner-restricted LP. Only authorized addresses can add or
remove liquidity, and all LP must be concentrated in a single tick spacing at
the active tick. Owner controls pricing via a single symmetric fee override.

**Note:**
security-contact: security@uniswap.org


## State Variables
### authorizedLPs
Whether an address is authorized to add or remove pool liquidity.


```solidity
mapping(address => bool) public authorizedLPs
```


## Functions
### constructor


```solidity
constructor(IPoolManager _poolManager, uint32 maxGas_, address owner_)
    SpreadQuoterBase(_poolManager, maxGas_, owner_);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolManager`|`IPoolManager`|The Uniswap v4 PoolManager.|
|`maxGas_`|`uint32`|     Gas budget declared for `getIndicativeQuote` staticcalls.|
|`owner_`|`address`|      Initial contract owner (Ownable2Step).|


### getHookPermissions

The v4 hook permissions for this contract.

`beforeInitialize` blocks direct PM init (force operator to use
`initializePool`); `afterInitialize` registers the active tick;
`beforeAddLiquidity` / `beforeRemoveLiquidity` enforce the LP allowlist;
`beforeSwap` applies the LP fee override.


```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory);
```

### _beforeAddLiquidity


```solidity
function _beforeAddLiquidity(
    address sender,
    PoolKey calldata key,
    ModifyLiquidityParams calldata params,
    bytes calldata
) internal view override returns (bytes4);
```

### _beforeRemoveLiquidity


```solidity
function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
    internal
    view
    override
    returns (bytes4);
```

### setAuthorizedLP

Authorize or revoke an address for LP operations.

Only the owner may toggle authorization. Emits [AuthorizedLPUpdated](/src/alf/SimpleSpreadQuoterHook.sol/contract.SimpleSpreadQuoterHook.md#authorizedlpupdated).


```solidity
function setAuthorizedLP(address lp, bool authorized) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lp`|`address`|        The address to authorize or revoke.|
|`authorized`|`bool`|True to grant LP access, false to revoke.|


## Events
### AuthorizedLPUpdated
Emitted when an LP's authorization is granted or revoked by the owner.


```solidity
event AuthorizedLPUpdated(address indexed lp, bool authorized);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`lp`|`address`|        The LP address whose authorization changed.|
|`authorized`|`bool`|True if the LP can now add/remove liquidity, false if revoked.|

## Errors
### UnauthorizedLP
Caller is not in the `authorizedLPs` allowlist.


```solidity
error UnauthorizedLP();
```

