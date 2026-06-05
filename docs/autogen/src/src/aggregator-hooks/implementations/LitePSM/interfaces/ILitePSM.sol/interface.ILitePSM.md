# ILitePSM
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/a4dd8463f7e31d29785c1d924a63dbe40a10ac05/src/aggregator-hooks/implementations/LitePSM/interfaces/ILitePSM.sol)

**Title:**
ILitePSM

Interface for MakerDAO's LitePSM and LitePSMWrapper contracts

The wrapper at 0xA188EEc8F81263234dA3622A406892F3D630f98c presents USDS ↔ USDC
The "gem" is USDC (6 decimals). USDS is 18 decimals.
to18ConversionFactor = 10^(18 - gem.decimals()) = 10^12 for USDC


## Functions
### sellGem

Sell gem (USDC) to receive USDS

Pulls gemAmt of gem from msg.sender; sends USDS to usr


```solidity
function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsAmt);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`usr`|`address`|Address to receive USDS|
|`gemAmt`|`uint256`|Amount of gem (USDC, 6 dec) to sell|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`usdsAmt`|`uint256`|Amount of USDS sent to usr|


### buyGem

Buy gem (USDC) by spending USDS

Pulls USDS from msg.sender; sends gemAmt of gem to usr


```solidity
function buyGem(address usr, uint256 gemAmt) external returns (uint256 usdsAmt);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`usr`|`address`|Address to receive gem (USDC)|
|`gemAmt`|`uint256`|Amount of gem (USDC, 6 dec) to receive|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`usdsAmt`|`uint256`|Amount of USDS pulled from msg.sender|


### tin

Fee rate for sellGem (USDC → USDS), in WAD (1e18 = 100%)


```solidity
function tin() external view returns (uint256);
```

### tout

Fee rate for buyGem (USDS → USDC), in WAD (1e18 = 100%)


```solidity
function tout() external view returns (uint256);
```

### to18ConversionFactor

Conversion factor from gem decimals to 18 decimals (10^(18 - gem.decimals()))


```solidity
function to18ConversionFactor() external view returns (uint256);
```

### gem

The gem token address (USDC)


```solidity
function gem() external view returns (address);
```

### pocket

The pocket contract that holds USDC liquidity


```solidity
function pocket() external view returns (address);
```

