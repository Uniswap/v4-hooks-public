# HookMinerCreate3
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/9bc2d1c28a0cd3cd0bb66585ac293b2a918ccfee/src/utils/HookMinerCreate3.sol)

**Title:**
HookMinerCreate3

A minimal library for mining hook addresses using CREATE3


## State Variables
### FLAG_MASK

```solidity
uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK
```


### MAX_LOOP

```solidity
uint256 constant MAX_LOOP = 160_444
```


## Functions
### find

Find a salt that produces a hook address with the desired `flags` using CREATE3


```solidity
function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
    internal
    view
    returns (address, bytes32);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`deployer`|`address`|The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)|
|`flags`|`uint160`|The desired flags for the hook address. Example `uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | ...)`|
|`creationCode`|`bytes`|The creation code of a hook contract. Example: `type(Counter).creationCode`|
|`constructorArgs`|`bytes`|The encoded constructor arguments of a hook contract. Example: `abi.encode(address(manager))`|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|(hookAddress, salt) The hook deploys to `hookAddress` when using `salt` with CREATE3|
|`<none>`|`bytes32`||


### computeAddress

Precompute a contract address deployed via CREATE3


```solidity
function computeAddress(address deployer, uint256 salt, bytes memory) internal pure returns (address hookAddress);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`deployer`|`address`|The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)|
|`salt`|`uint256`|The salt used to deploy the hook|
|`<none>`|`bytes`||


### findWithPrefix

Find a salt that produces a hook address with the desired `flags` using CREATE3 with a custom salt prefix


```solidity
function findWithPrefix(
    address deployer,
    uint160 flags,
    bytes memory creationCode,
    bytes memory constructorArgs,
    string memory saltPrefix
) internal view returns (address, bytes32);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`deployer`|`address`|The address that will deploy the hook|
|`flags`|`uint160`|The desired flags for the hook address|
|`creationCode`|`bytes`|The creation code of a hook contract|
|`constructorArgs`|`bytes`|The encoded constructor arguments of a hook contract|
|`saltPrefix`|`string`|A prefix to use for the salt (e.g., "permissioned-router-")|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|(hookAddress, salt) The hook deploys to `hookAddress` when using `salt` with CREATE3|
|`<none>`|`bytes32`||


