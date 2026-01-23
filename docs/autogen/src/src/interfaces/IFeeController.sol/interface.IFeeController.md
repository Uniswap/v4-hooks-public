# IFeeController
[Git Source](https://github.com/Uniswap/v4-hooks/blob/cc39bad2f9286aefd0824c4bc93d241fe8657275/src/interfaces/IFeeController.sol)

Interface for the FeeController


## Functions
### setFeeController

Set the fee controller


```solidity
function setFeeController(address newFeeController) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newFeeController`|`address`|The address of the new fee controller|


## Events
### FeeControllerUpdated
Event emitted when the fee controller is updated


```solidity
event FeeControllerUpdated(address indexed feeController);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`feeController`|`address`|The new fee controller|

## Errors
### NotFeeController
Error thrown when the caller is not the fee controller


```solidity
error NotFeeController(address caller);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`caller`|`address`|The invalid address attempting to update the pool fee data|

