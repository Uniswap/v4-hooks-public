# FeeController
[Git Source](https://github.com/Uniswap/v4-hooks/blob/cc39bad2f9286aefd0824c4bc93d241fe8657275/src/FeeController.sol)

**Inherits:**
[IFeeController](/src/interfaces/IFeeController.sol/interface.IFeeController.md)

**Title:**
FeeController

Abstract contract that implements the IFeeController interface


## State Variables
### feeController
The address of the fee controller

The fee controller is the address that can update the fee configuration for a pool


```solidity
address public feeController
```


## Functions
### constructor


```solidity
constructor(address _feeController) ;
```

### onlyFeeController

Modifier to only allow calls from the fee controller

This modifier is used to prevent unauthorized updates to the fee configuration per pool


```solidity
modifier onlyFeeController() ;
```

### setFeeController

Set the fee controller


```solidity
function setFeeController(address newFeeController) external onlyFeeController;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newFeeController`|`address`|The address of the new fee controller|


