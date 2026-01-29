# Aggregator Hooks

Uniswap V4 hooks that aggregate liquidity from external DEX protocols, enabling unified liquidity access through Uniswap V4's interface.

## Supported Protocols

### Curve Finance

| Pool Type | Implementation | Description |
|-----------|----------------|-------------|
| **StableSwap** | `StableSwapAggregator` | Classic Curve stableswap pools (e.g., 3pool, stETH/ETH) |
| **StableSwapNG** | `StableSwapNGAggregator` | Next-generation Curve pools with improved features |

### Fluid (Instadapp)

| Pool Type | Implementation | Description |
|-----------|----------------|-------------|
| **FluidDexT1** | `FluidDexT1Aggregator` | Fluid DEX v1 pools with collateral and debt reserves |
| **FluidDexLite** | `FluidDexLiteAggregator` | Lightweight Fluid DEX pools |
| **FluidDexV2** | `FluidDexV2Aggregator` | Fluid DEX v2 concentrated liquidity pools (Mainnet launch TBD) |

## Custom Interfaces

Each implementation includes its own interface definitions rather than importing from external libraries. This is necessary because:

1. **Curve Finance**: Curve contracts are written in **Vyper**, so there are no Solidity interfaces to import. We define minimal Solidity interfaces that match Curve's ABI.

2. **Fluid (Instadapp)**: The official [`fluid-contracts-public`](https://github.com/Instadapp/fluid-contracts-public) library uses **exact Solidity version pragmas** (`pragma solidity 0.8.21;` and `0.8.29;`) that are incompatible with Uniswap V4's requirement of `^0.8.24`. Since these version constraints don't overlap, we maintain our own interface definitions.

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
