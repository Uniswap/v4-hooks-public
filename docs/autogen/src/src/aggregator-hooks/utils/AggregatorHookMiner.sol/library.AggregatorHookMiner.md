# AggregatorHookMiner
[Git Source](https://github.com/Uniswap/v4-hooks-internal/blob/44f569c0f2c8bf659eb1f2f462038e29b30030c3/src/aggregator-hooks/utils/AggregatorHookMiner.sol)

**Title:**
AggregatorHookMiner

a minimal library for mining aggregator hook addresses

This library is a version of HookMiner that incorporates the aggregator hook identification system.


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

Find a salt that produces a hook address with the desired `flags` and first byte ID


```solidity
function find(
    address deployer,
    uint160 flags,
    uint8 firstByte,
    bytes memory creationCode,
    bytes memory constructorArgs,
    uint256 saltOffset
) internal view returns (address, bytes32);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`deployer`|`address`|The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)|
|`flags`|`uint160`|The desired flags for the hook address. Example `uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | ...)`|
|`firstByte`|`uint8`|The desired first byte of the hook address (e.g., 0xC1 for StableSwap, 0xC2 for StableSwap-NG, 0xF1 for FluidDexT1, 0x71 for TempoExchange, etc.)|
|`creationCode`|`bytes`|The creation code of a hook contract. Example: `type(Counter).creationCode`|
|`constructorArgs`|`bytes`|The encoded constructor arguments of a hook contract. Example: `abi.encode(address(manager))`|
|`saltOffset`|`uint256`|The starting salt value for the search. Increment by MAX_LOOP for subsequent attempts.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|hookAddress The computed hook address|
|`<none>`|`bytes32`|salt The salt that produces the hook address|


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

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`hookAddress`|`address`|The address of the hook|


