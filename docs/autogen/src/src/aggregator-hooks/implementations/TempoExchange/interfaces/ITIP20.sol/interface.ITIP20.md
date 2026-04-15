# ITIP20
[Git Source](https://github.com/Uniswap/v4-hooks-public/blob/56f51601c343010d27d45c492f27de85ad1a03d2/src/aggregator-hooks/implementations/TempoExchange/interfaces/ITIP20.sol)

Interface for Tempo TIP-20 tokens (precompile stablecoins)

*Each TIP-20 token defines a quoteToken() forming a DEX tree. PathUSD is the root (quoteToken = address(0)).*


## Functions
### name

Returns the token name


```solidity
function name() external view returns (string memory);
```

### symbol

Returns the token symbol


```solidity
function symbol() external view returns (string memory);
```

### quoteToken

Returns the parent token in the DEX tree

*PathUSD (the root token) returns address(0)*


```solidity
function quoteToken() external view returns (address);
```

### totalSupply

Returns the total supply of the token


```solidity
function totalSupply() external view returns (uint256);
```

