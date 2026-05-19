# Aggregator Hooks

Uniswap V4 hooks that aggregate liquidity from external DEX protocols, enabling unified liquidity access through Uniswap V4's interface.

## Adding support for a new protocol

When adding support for a new protocol, you must follow these guidelines:

- If the protocol has a strict 1-1 mapping for a UniswapV4 Pool Key, the implementation contract must be a singleton
- If the protocol has a strict 1-1 mapping for a UniswapV4 Pool Key, there should not be a factory
- Update the MineAggregatorHook script to handle mining hooks for new protocol
- For testing requirements, see test/aggreagtor-hooks/README.md

## ID System

The ID system is for convenience of routing programs to know which protocols the external liquidity source belongs to. This is useful for knowing when there is interaction with the same pool more than once in a route. Any random hook address does have a 1/256 chance of a false positive, so anyone relying on the ID system should be aware of that.

Aggregator Hook contract addresses should adhere to the following identification system:

- The first character should be the same as first character of the protocol ("c" for Curve, "f" for Fluid, "b" for Balancer, etc)
- The second character should represent the contract type/version.
  This can be done with the modified HookMiner contract.

First-byte ID table:

| ID  | Protocol/Pool Type |
| --- | ------------------ |
| C1  | StableSwap         |
| C2  | StableSwap-NG      |
| F1  | FluidDexT1         |
| F2  | FluidDexV2         |
| F3  | FluidDexLite       |
| 71  | TempoExchange      |
| E1  | ElfomoFi           |

## Supported Protocols

### Curve Finance

One hook is deployed per curve pool, despite one curve pool resulting in ((n \* (n-1)) / 2) Uniswap V4 pools. This means that for a Curve pool with 8 tokens, all 28 UniswapV4 pools associated with that pool use the same hook.

This design allows routing to know when they are interacting with the same Curve pool by checking for duplicate hook addresses, which is important since swaps in one direction will affect all other directions including one of the touched tokens.

| Pool Type        | Implementation           | Description                                             |
| ---------------- | ------------------------ | ------------------------------------------------------- |
| **StableSwap**   | `StableSwapAggregator`   | Classic Curve stableswap pools (e.g., 3pool, stETH/ETH) |
| **StableSwapNG** | `StableSwapNGAggregator` | Next-generation Curve pools with improved features      |

#### Defined interfaces

Curve interfaces, matching Curve's ABIs are defined inside the project. This is because Curve contracts are written in **Vyper**, so there are no Solidity interfaces to import.

### Fluid (Instadapp)

One hook is deployed per Fluid pool.

| Pool Type        | Implementation           | Description                                                    |
| ---------------- | ------------------------ | -------------------------------------------------------------- |
| **FluidDexT1**   | `FluidDexT1Aggregator`   | Fluid DEX v1 pools with collateral and debt reserves           |
| **FluidDexLite** | `FluidDexLiteAggregator` | Lightweight Fluid DEX pools                                    |
| **FluidDexV2**   | `FluidDexV2Aggregator`   | Fluid DEX v2 concentrated liquidity pools (Mainnet launch TBD) |

#### Defined interfaces

Fluid interfaces, matching Fluid's ABI, are defined inside the project. This is because the official [`fluid-contracts-public`](https://github.com/Instadapp/fluid-contracts-public) library uses **exact Solidity version pragmas** (`pragma solidity 0.8.21;` and `0.8.29;`) that are incompatible with Uniswap V4's requirement of `^0.8.24`. Since these version constraints don't overlap, we maintain our own interface definitions.

### Tempo

Tempo is a blockchain for payments with an enshrined stablecoin DEX. A singleton hook supports multiple token pairs.

| Pool Type         | Implementation            | Description                                             |
| ----------------- | ------------------------- | ------------------------------------------------------- |
| **TempoExchange** | `TempoExchangeAggregator` | Tempo's enshrined stablecoin DEX (precompiled contract) |

#### Key Details

- **Chain**: Tempo is a separate EVM-compatible chain, not Ethereum mainnet
- **Exchange Address**: `0xDEc0000000000000000000000000000000000000` (precompiled)
- **Amount Precision**: Uses `uint128` for amounts (not `uint256`)
- **Decimals**: All stablecoins use 6 decimals
- **Features**: Supports both exact-input and exact-output swaps with view quote functions

#### Defined interfaces

The interface is defined based on Tempo's [official documentation](https://docs.tempo.xyz/protocol/exchange/executing-swaps).

### ElfomoFi

ElfomoFi is a PropAMM whose prices are updated each block by an offchain oracle plus onchain signals. A singleton hook supports multiple token pairs (one canonical V4 pool per pair).

| Pool Type     | Implementation        | Description                                           |
| ------------- | --------------------- | ----------------------------------------------------- |
| **ElfomoFi**  | `ElfomoFiAggregator`  | Singleton ElfomoFi PropAMM router on Base and BSC     |

#### Key Details

- **Chains**: Base, BSC
- **Router Address**: `0xf0f0F0F0FB0d738452EfD03A28e8be14C76d5f73` (same on both chains)
- **Swap Path**: `swapWithCallback` (no standing token approval; ElfomoFi pulls input tokens via the `IElfomoSwapCallback` callback)
- **Quote Path**: `getAmountOut` / `getAmountIn`; both quote and execution route through the same pricing oracle, so quote-to-execute drift inside one transaction is zero
- **Partner ID**: constructor-immutable on the hook; defaults to `0` ("not used") until Uniswap is assigned an ElfomoFi partner identifier. **Note**: ElfomoFi's deployed `getAmountOut` / `getAmountIn` hard-code `partnerId = 0`; if a non-zero partner ID is later set on the hook, the public `quote()` may diverge from execution if the ElfomoFi pricing oracle prices partners differently.
- **Native ETH**: not supported in v1 (reverts in `_beforeInitialize`)
- **Owner**: holds `deregisterPair` capability only — can evict a squatter that front-ran the team's intended `initialize()`. The owner has no other privileges and cannot move funds.

#### Defined interfaces

ElfomoFi interfaces are derived from the verified deployed source at `0xf0f0F0F0FB0d738452EfD03A28e8be14C76d5f73` on Base and the docs at https://docs.elfomo.fi/integration/.

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

All aggregators extend `BaseAggregatorHook`, which provides the base hook functionality for routing swaps through external liquidity sources.
