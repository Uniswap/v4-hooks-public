# AllowlistedFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/6d655caad05e418639ee631761d79f041c6299ee/src/AllowlistedFactory.sol)

**Inherits:**
[IAllowlistedFactory](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md)

**Title:**
AllowlistedFactory

**Author:**
Uniswap Labs

A CREATE2 deployer and discovery registry restricted to an immutable allowlist of
creation-code hashes. It is intended to be used with canonical hook implementations:
aggregators and third-party routers watch {Deployed} events (or enumerate
{allDeployments}) to find new hooks, then follow each hook's `PoolCreated` events for
its pools, and each hook points back here via its `factory()` getter so provenance is
checkable from either side. Nothing in the contract is hook-specific, so any family
of hooks can reuse it by deploying an instance pinned to their hashes.
## Why the caller supplies the creation code
Allowlisted contracts' creation code are not embedded in this factory's own runtime.
Instead, it is passed as calldata to [deploy](/src/AllowlistedFactory.sol/contract.AllowlistedFactory.md#deploy) and accepted only if its keccak256 hash
is on the allowlist fixed at construction. Registered deployments are therefore
guaranteed to match known implementations. Constructor arguments are just opaque bytes
appended to the creation code, so the factory carries no assumptions about any the
contract's constructor shape; the allowlisted hash identifies the contract and how to
decode its arguments.
## Trust model
The allowlist is immutable: there is no owner and no way to add or remove creation
code post-deployment, so `isFromFactory` can never be made to vouch for foreign
bytecode. Deployment is permissionless and constructor arguments (including any
owner) are the deployer's choice; registration attests bytecode provenance, not
operator trustworthiness. New contract versions require a new factory.
## CREATE2 and hook salt mining
This factory is the CREATE2 deployer, so deterministic addresses derive from ITS
address. For v4 hooks that means flag/vanity salts must be mined against the factory
(see `script/mine_dualpool_salt.sh`), and the hook's BaseHook constructor validates
the resulting address's permission flags, so a stale or wrong-deployer salt reverts
instead of deploying a broken hook. Deploy transactions are not meaningfully
front-runnable: identical inputs produce the identical contract at the identical
address, so a sniped deployment only reverts the victim's transaction after the
intended contract already exists.

**Note:**
security-contact: security@uniswap.org


## State Variables
### isAllowedCreationCode

```solidity
mapping(bytes32 creationCodeHash => bool allowed) public override isAllowedCreationCode
```


### creationCodeHashOf

```solidity
mapping(address deployed => bytes32 creationCodeHash) public override creationCodeHashOf
```


### allDeployments

```solidity
address[] public override allDeployments
```


## Functions
### constructor


```solidity
constructor(bytes32[] memory creationCodeHashes) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`creationCodeHashes`|`bytes32[]`|keccak256 hashes of the creation code deployable through this factory (e.g. `keccak256(type(DualPoolHook).creationCode)`). Must be non-empty with no zero entries; fixed forever.|


### deploy

Deploy allowlisted creation code via CREATE2 and register the result.

The caller supplies the creation code because allowlisted contracts may sit near
the EIP-170 size limit: embedding their creation code in the factory's runtime
would be impossible, so it is passed in and pinned by hash instead. Constructor
arguments are opaque to the factory; the CREATE2 init code is
`abi.encodePacked(creationCode, constructorArgs)`, exactly what a direct
`new Contract{salt: salt}(...)` would run, and malformed arguments revert inside
the constructor. For v4 hooks, the hook's own constructor (BaseHook) validates
that the resulting address encodes the correct permission flags, so a salt not
mined against this factory reverts here.


```solidity
function deploy(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
    external
    override
    returns (address deployed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`creationCode`|`bytes`|   Creation code of an allowlisted contract, e.g. `type(DualPoolHook).creationCode`.|
|`constructorArgs`|`bytes`|ABI-encoded constructor arguments for that contract.|
|`salt`|`bytes32`|           CREATE2 salt; this factory is the CREATE2 deployer (see `script/mine_dualpool_salt.sh` for hook salt mining).|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`deployed`|`address`|The deployed contract address.|


### computeAddress

Predict the address {deploy} would deploy to for the given inputs.


```solidity
function computeAddress(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
    external
    view
    override
    returns (address deployed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`creationCode`|`bytes`|   Creation code of the contract.|
|`constructorArgs`|`bytes`|ABI-encoded constructor arguments.|
|`salt`|`bytes32`|           CREATE2 salt.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`deployed`|`address`|The counterfactual address.|


### isFromFactory

Whether an address was deployed by this factory.


```solidity
function isFromFactory(address deployed) external view override returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`deployed`|`address`|The address to check.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if {deploy} deployed it.|


### allDeploymentsLength

Total number of contracts deployed through this factory.


```solidity
function allDeploymentsLength() external view override returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Number of registry entries, for onchain enumeration of {allDeployments}.|


