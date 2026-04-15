# HookMiner
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/56f51601c343010d27d45c492f27de85ad1a03d2/src/utils/HookMiner.sol)

a minimal library for mining hook addresses


## State Variables
### FLAG_MASK

```solidity
uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK;
```


### MAX_LOOP

```solidity
uint256 constant MAX_LOOP = 160_444;
```


## Functions
### find

Find a salt that produces a hook address with the desired `flags`


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
|`<none>`|`address`|(hookAddress, salt) The hook deploys to `hookAddress` when using `salt` with the syntax: `new Hook{salt: salt}(<constructor arguments>)`|
|`<none>`|`bytes32`||


### computeAddress

Precompute a contract address deployed via CREATE2


```solidity
function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
    internal
    pure
    returns (address hookAddress);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`deployer`|`address`|The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)|
|`salt`|`uint256`|The salt used to deploy the hook|
|`creationCodeWithArgs`|`bytes`|The creation code of a hook contract, with encoded constructor arguments appended. Example: `abi.encodePacked(type(Counter).creationCode, abi.encode(constructorArg1, constructorArg2))`|


