# IAllowlistedFactory
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/6d655caad05e418639ee631761d79f041c6299ee/src/interfaces/IAllowlistedFactory.sol)

**Title:**
IAllowlistedFactory

**Author:**
Uniswap Labs

A CREATE2 deployer and discovery registry restricted to an immutable allowlist of
creation-code hashes. Deployed for the DualPool hook family so aggregators and
third-party routers can find and verify hooks, but generic: it works for any
contract whose creation code is pinned at factory construction.
Integrators discover deployments in two ways:
- Offchain: index [Deployed](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md#deployed) events from the factory.
- Onchain: enumerate [allDeployments](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md#alldeployments) / [allDeploymentsLength](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md#alldeploymentslength), or verify a
candidate address with [isFromFactory](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md#isfromfactory).
Provenance, not endorsement: a registered address is a bit-exact build of
allowlisted bytecode, but deployment is permissionless and constructor arguments
(including any owner) are the deployer's choice. Integrators must still evaluate
the operator behind a deployment.


## Functions
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

Predict the address [deploy](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md#deploy) would deploy to for the given inputs.


```solidity
function computeAddress(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
    external
    view
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


### isAllowedCreationCode

Whether a creation-code hash is deployable through this factory.


```solidity
function isAllowedCreationCode(bytes32 creationCodeHash) external view returns (bool allowed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`creationCodeHash`|`bytes32`|keccak256 of a contract's creation code.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`allowed`|`bool`|True if [deploy](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md#deploy) accepts creation code with this hash.|


### creationCodeHashOf

The creation-code hash a registered contract was deployed from.


```solidity
function creationCodeHashOf(address deployed) external view returns (bytes32 creationCodeHash);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`deployed`|`address`|A deployed contract address.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`creationCodeHash`|`bytes32`|keccak256 of its creation code, or `bytes32(0)` if the address was not deployed by this factory.|


### isFromFactory

Whether an address was deployed by this factory.


```solidity
function isFromFactory(address deployed) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`deployed`|`address`|The address to check.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True if [deploy](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md#deploy) deployed it.|


### allDeployments

The contract deployed at position `index`, in deployment order.


```solidity
function allDeployments(uint256 index) external view returns (address deployed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`index`|`uint256`|Position in the registry, `< allDeploymentsLength()`.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`deployed`|`address`|The contract address.|


### allDeploymentsLength

Total number of contracts deployed through this factory.


```solidity
function allDeploymentsLength() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Number of registry entries, for onchain enumeration of [allDeployments](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md#alldeployments).|


## Events
### Deployed
Emitted for every contract deployed through the factory. The primary offchain
discovery signal.


```solidity
event Deployed(
    address indexed deployed,
    bytes32 indexed creationCodeHash,
    address indexed deployer,
    bytes constructorArgs,
    bytes32 salt
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`deployed`|`address`|        The deployed contract address.|
|`creationCodeHash`|`bytes32`|keccak256 of the creation code; identifies which allowlisted contract was deployed, and therefore the ABI shape of `constructorArgs` (decode offchain against that contract's constructor, e.g. `(address, uint32, address, uint64)` for the DualPool hook family: PoolManager, maxGas, owner, maxMinDepositBlocks).|
|`deployer`|`address`|        The account that called [deploy](/src/interfaces/IAllowlistedFactory.sol/interface.IAllowlistedFactory.md#deploy).|
|`constructorArgs`|`bytes`| The ABI-encoded constructor arguments used.|
|`salt`|`bytes32`|            The CREATE2 salt used (for v4 hooks, mined for permission flags and vanity prefix).|

## Errors
### CreationCodeNotAllowed
The supplied creation code's hash is not on the factory's allowlist.


```solidity
error CreationCodeNotAllowed(bytes32 creationCodeHash);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`creationCodeHash`|`bytes32`|keccak256 of the rejected creation code.|

### InvalidAllowlist
The factory was constructed with an empty or zero-valued allowlist entry.


```solidity
error InvalidAllowlist();
```

