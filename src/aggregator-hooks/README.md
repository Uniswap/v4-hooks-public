# Aggregator Hooks

Uniswap V4 hooks that aggregate liquidity from external DEX protocols, enabling unified liquidity access through Uniswap V4's interface.

## ID System:

Aggregator Hook contract addresses should adhere to the following identification system:
 - The first character should be the same as first character of the protocol ("c" for Curve, "f", for Fluid, "b" for Balancer, etc)
 - The second character should be the contract type/version.
 This can be done with the modified HookMiner contract.

 First-byte ID table:

| ID | Protocol/Pool Type |
|----|-------------------|
| C1 | StableSwap |
| C2 | StableSwap-NG |
| F1 | FluidDexT1 |
| F2 | FluidDexV2 |
| F3 | FluidDexLite |

## Supported Protocols

### Curve Finance

One hook is deployed per curve pool, despite one curve pool resulting in ((n * (n-1)) / 2) Uniswap V4 pools. This means that for a Curve pool with 8 tokens, all 28 UniswapV4 pools associated with that pool use the same hook. 

This design allows routing to know when they are interacting with the same Curve pool by checking for duplicate hook addresses, which is important since swaps in one direction will effect all other directions including one of the touched tokens.

| Pool Type | Implementation | Description |
|-----------|----------------|-------------|
| **StableSwap** | `StableSwapAggregator` | Classic Curve stableswap pools (e.g., 3pool, stETH/ETH) |
| **StableSwapNG** | `StableSwapNGAggregator` | Next-generation Curve pools with improved features |

#### Defined interfaces

Curve interfaces, matching Curve's ABIs are defined inside the project. This is because Curve contracts are written in **Vyper**, so there are no Solidity interfaces to import.  

### Fluid (Instadapp)

One hook is deployed per Fluid pool.

| Pool Type | Implementation | Description |
|-----------|----------------|-------------|
| **FluidDexT1** | `FluidDexT1Aggregator` | Fluid DEX v1 pools with collateral and debt reserves |
| **FluidDexLite** | `FluidDexLiteAggregator` | Lightweight Fluid DEX pools |
| **FluidDexV2** | `FluidDexV2Aggregator` | Fluid DEX v2 concentrated liquidity pools (Mainnet launch TBD) |

#### Defined interfaces

Fluid interfaces, matching Fluid's ABI, are defined inside the project. This is because the official [`fluid-contracts-public`](https://github.com/Instadapp/fluid-contracts-public) library uses **exact Solidity version pragmas** (`pragma solidity 0.8.21;` and `0.8.29;`) that are incompatible with Uniswap V4's requirement of `^0.8.24`. Since these version constraints don't overlap, we maintain our own interface definitions.

## Architecture

Each aggregator implementation follows a consistent pattern:

```
implementations/
└── {ProtocolPoolType}/
    ├── {ProtocolPoolType}Aggregator.sol          # Hook implementation
    ├── {ProtocolPoolType}AggregatorFactory.sol   # Factory for CREATE2 deployment
    └── interfaces/
        └── I{Protocol}.sol                       # Protocol-specific interfaces
```

All aggregators extend `ExternalLiqSourceHook`, which provides the base hook functionality for routing swaps through external liquidity sources.
