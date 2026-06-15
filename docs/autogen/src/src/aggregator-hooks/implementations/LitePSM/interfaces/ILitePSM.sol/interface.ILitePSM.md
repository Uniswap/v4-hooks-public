# ILitePSM
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/307b1b2cf75bf77abe89e8a25717902b77f19142/src/aggregator-hooks/implementations/LitePSM/interfaces/ILitePSM.sol)

**Title:**
ILitePSM

Interface for MakerDAO's LitePSM and LitePSMWrapper contracts

Compatible with:
- LitePSMWrapper (0xA188EEc8F81263234dA3622A406892F3D630f98c): gem=USDC, stable=USDS
- LitePSM-DAI-USDC (0xf6e72Db5454dd049d0788e411b06CfAF16853042): gem=USDC, stable=DAI
The "gem" is the collateral token (USDC, 6 decimals); the stable is 18 decimals.
to18ConversionFactor = 10^(18 - gem.decimals()) = 10^12 for USDC


## Functions
### sellGem

Sell gem to receive stable (e.g. USDC → USDS or USDC → DAI)

Pulls gemAmt of gem from msg.sender; sends stable to usr


```solidity
function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsAmt);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`usr`|`address`|Address to receive stable|
|`gemAmt`|`uint256`|Amount of gem (6 dec) to sell|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`usdsAmt`|`uint256`|Amount of stable sent to usr|


### buyGem

Buy gem by spending stable (e.g. USDS → USDC or DAI → USDC)

Pulls stable from msg.sender; sends gemAmt of gem to usr


```solidity
function buyGem(address usr, uint256 gemAmt) external returns (uint256 usdsAmt);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`usr`|`address`|Address to receive gem|
|`gemAmt`|`uint256`|Amount of gem (6 dec) to receive|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`usdsAmt`|`uint256`|Amount of stable pulled from msg.sender|


### tin

Fee rate for sellGem (gem → stable), in WAD (1e18 = 100%)


```solidity
function tin() external view returns (uint256);
```

### tout

Fee rate for buyGem (stable → gem), in WAD (1e18 = 100%)


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

The pocket contract that holds gem liquidity


```solidity
function pocket() external view returns (address);
```

### buf

Pre-minted stable buffer target held in this PSM (WAD, 18 decimals)

Used as a conservative proxy for sellGem capacity.
The true sellGem cap is `min(buf, line - Art*RAY) / to18ConversionFactor` (gem units),
but line/Art are only available on the underlying Vat and are not exposed by the wrapper.
Using buf alone may overestimate capacity when the debt ceiling is simultaneously binding,
but in normal operation buf is kept well below the ceiling.


```solidity
function buf() external view returns (uint256);
```

