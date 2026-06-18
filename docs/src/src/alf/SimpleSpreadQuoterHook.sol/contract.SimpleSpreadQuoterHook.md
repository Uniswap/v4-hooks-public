# SimpleSpreadQuoterHook
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/0c68c6912ec9b3df692fd62740997db52f245b7d/src/alf/SimpleSpreadQuoterHook.sol)

**Inherits:**
[SpreadQuoterBase](/src/alf/base/SpreadQuoterBase.sol/abstract.SpreadQuoterBase.md)

**Title:**
SimpleSpreadQuoterHook

**Author:**
Uniswap Labs

Spread quoter with owner-restricted LP. Only authorized addresses can add or
remove liquidity, and all LP must be concentrated in a single tick spacing at
the active tick. Owner controls pricing via a single symmetric fee override.
## Trust model — `authorizedLPs` is operator-only, not a public LP allowlist
`authorizedLPs` is designed as an allowlist of addresses controlled by a single
trust principal (the operator), NOT as a registry of independent third-party LPs.
Typical configurations: a treasury contract + an algorithmic-execution hot wallet;
a multisig + a routine-operations EOA; a primary and a backup. All entries are
expected to be in coordination with one another.
The hook does NOT track per-LP positions. Two consequences follow:
1. **Revocation locks the revoked LP's outstanding funds.** If LP A holds a v4
position in this pool and the owner calls `setAuthorizedLP(A, false)`, A's
subsequent `removeLiquidity` reverts at `_beforeRemoveLiquidity`'s
authorization check. A's funds remain locked until re-authorization. Owners
MUST sequence "drain then revoke" when retiring an LP address.
2. **`setActiveTick` enforces drain-before-relocate.** The base now refuses to
move `activeLowerTick` while liquidity is still referenced at the prior band
(reverts with `ActiveTickBandNonEmpty`). Operators MUST have the authorized
LP remove its position at the old tick before calling `setActiveTick` with a
different value. Setting the same tick remains an idempotent no-op.
Use cases that need genuine multi-tenant LP (independent users supplying
liquidity, hook manages spread) are OUT OF SCOPE for this contract and would
require a separate hook with per-LP position tracking.

This is NOT intended as a production-ready hook. It is a reference implementation
designed to demonstrate the core mechanics of a spread-based quoter where LP is
controlled by a single owner. Although it may work for simple use cases, it is not
expected to be used in production as-is.

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

`beforeInitialize` blocks direct PM init (forces operator to use
`initializePool`); `beforeAddLiquidity` / `beforeRemoveLiquidity` enforce the LP
allowlist; `beforeSwap` enforces the liveness flag. Pricing is fully static
(`key.fee`) -- no LP fee override is returned from `_beforeSwap`.


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
**WARNING — revocation locks outstanding liquidity.** This contract has no
per-LP position tracking, so revoking `lp` while `lp` holds a v4 position in
any pool gated by this hook makes that position un-removable until
`lp` is re-authorized. Owners MUST sequence revocations as
"drain (have `lp` remove its positions) THEN revoke" -- never the reverse.
See the contract-level `Trust model` NatSpec for more context onthe operator-only
design intent and the trade-offs involved.


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

