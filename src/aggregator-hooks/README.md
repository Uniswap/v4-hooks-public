# Aggregator Hooks

Uniswap V4 hooks that aggregate liquidity from external DEX protocols, enabling unified liquidity access through Uniswap V4's interface.

## Adding support for a new protocol

When adding support for a new protocol, you must follow these guidelines:

- If the protocol has a strict 1-1 mapping for a UniswapV4 Pool Key, the implementation contract must be a singleton
- If the protocol has a strict 1-1 mapping for a UniswapV4 Pool Key, there should not be a factory
- Update the MineAggregatorHook script to handle mining hooks for new protocol
- For testing requirements, see test/aggregator-hooks/README.md

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
| 03  | Uniswap V3         |
| A1  | Slipstream         |
| 93  | Pancakeswap V3     |
| 95  | LitePSM            |
| 02  | Uniswap V2         |
| DC  | UniswapX (Dutch)   |

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

### Uniswap V2

Singleton hook routes swaps through **Uniswap V2–compatible** pairs (`getReserves`, constant-product `swap`). One deployment serves many Uniswap V4 pools; each external pair is resolved from the immutable factory via **`getPair(tokenA, tokenB)`**. On-chain reserves supply **view quotes**; `PoolKey.fee` and `PoolKey.tickSpacing` **do not** participate in routing (only the currency pair matters).

| Pool Type      | Implementation        | Factory lookup                                                                                   |
| -------------- | --------------------- | ------------------------------------------------------------------------------------------------ |
| **Uniswap V2** | `UniswapV2Aggregator` | `getPair(tokenA, tokenB)` — align `PoolKey` currencies with the pair’s `token0` / `token1` order |

#### Defined interfaces

Minimal interfaces live under `implementations/UniswapV2/interfaces/` (`IUniswapV2Pair`, `IUniswapV2Factory`) for the subset of the canonical V2 ABI the hook uses.

### MakerDAO LitePSM

Singleton hook routes swaps through **MakerDAO's LitePSM** (or `LitePSMWrapper`), which maintains a 1:1 peg between a gem token (e.g., USDC) and USDS. Because the PSM offers zero-slippage, fixed-fee conversion, no external factory lookup is needed — the hook addresses the PSM directly.

| Pool Type   | Implementation      | Routing                                                                                       |
| ----------- | ------------------- | --------------------------------------------------------------------------------------------- |
| **LitePSM** | `LitePSMAggregator` | Singleton; gem ↔ USDS via `sellGem` / `buyGem`. One pool per gem/USDS pair enforced at init. |

#### Key Details

- **Gem token**: resolved dynamically from `litePSM.gem()` at construction — not hardcoded to USDC
- **Decimal conversion**: `to18ConversionFactor` cached from `litePSM.to18ConversionFactor()` (e.g., `1e12` for 6-decimal gems)
- **Fees**: `tin` (gem→USDS) and `tout` (USDS→gem) are read fresh each call; governance can change them
- **Canonical pair**: only one V4 pool per gem/USDS pair is allowed; duplicate registration reverts with `PairAlreadyHasCanonicalPool`

#### Defined interfaces

A minimal `ILitePSM` interface lives under `implementations/LitePSM/interfaces/` covering `sellGem`, `buyGem`, `tin`, `tout`, `to18ConversionFactor`, `gem`, and `pocket`.

### Uniswap V3 / Slipstream

Singleton hooks route swaps through **Uniswap V3–compatible** pools (`swap` + `uniswapV3SwapCallback`). One deployment serves many Uniswap V4 pools; each external pool is keyed by factory plus tokens plus either **fee tier** (Uniswap V3 factory) or **tick spacing** (Slipstream factory).

| Pool Type      | Implementation         | Factory lookup                                                                                |
| -------------- | ---------------------- | --------------------------------------------------------------------------------------------- |
| **Uniswap V3** | `UniswapV3Aggregator`  | `getPool(tokenA, tokenB, fee)` — align `PoolKey.fee` with the external fee tier               |
| **Slipstream** | `SlipstreamAggregator` | `getPool(tokenA, tokenB, tickSpacing)` — align `PoolKey.tickSpacing` with the Slipstream pool |

`SlipstreamAggregator` inherits `UniswapV3Aggregator` and overrides only external pool resolution (and canonical secondary key). Quotes use a chain-deployed **Quoter** compatible with `IQuoterV2`.

#### Defined interfaces

Minimal interfaces live under `implementations/UniswapV3/interfaces/` and `implementations/Slipstream/interfaces/` (`IUniswapV3Pool`, `IUniswapV3Factory`, `ISlipstreamFactory`, `IQuoterV2`, `IUniswapV3SwapCallback`) so the repo does not require a full `v3-core` submodule.

### UniswapX (Dutch orders)

The "liquidity source" is a single **UniswapX order** (e.g. an original Dutch order), supplied as swap `hookData` rather than a persistent on-chain pool. The hook acts as the UniswapX **filler**: it calls the Reactor's `executeWithCallback`, the Reactor pulls the order swapper's input (via Permit2) to the hook and invokes `reactorCallback`, during which the hook sources the order's required output from the V4 PoolManager (i.e. from the V4 swapper). The V4 swapper therefore provides the counter-side liquidity that fills the order and, in return, receives the order's input token. The Reactor address is fixed at construction (one hook deployment per reactor).

| Pool Type    | Implementation       | Order delivery                                     |
| ------------ | -------------------- | -------------------------------------------------- |
| **UniswapX** | `UniswapXAggregator` | `SignedOrder` ABI-encoded and passed as `hookData` |

#### Key Details

- **No Quoter needed**: the Reactor resolves the order (applying Dutch decay) and returns the exact `ResolvedOrder` (input + outputs) inside `reactorCallback`.
- **All-or-nothing**: original Dutch orders cannot be partially filled, so the V4 swap amount must exactly match the resolved order amount, otherwise the swap reverts (`OrderAmountMismatch`).
- **No routing quotes**: `quote` / `pseudoTotalValueLocked` revert (`QuoteNotSupported`) because the order is only known at swap time, not when a router calls those view functions. This hook is solver-driven.
- **Protocol fees must be 0**: an exact order fill leaves no surplus to skim, so a non-zero protocol fee on the pool would break settlement.
- **ETH/WETH**: native ETH on the V4 pool side is bridged to/from WETH on the order side (order inputs are always ERC20 because Permit2 cannot transfer native ETH; order outputs may be native ETH or WETH). WETH address is fixed at construction.

#### Defined interfaces

UniswapX interfaces are imported from the [`briefcase`](https://github.com/Uniswap/briefcase) submodule via the `@uniswapx/` remapping (`IReactor`, `IReactorCallback`, `ReactorStructs`).

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

### `hookData`-driven aggregators

Most aggregators ignore the swap's `hookData` (their external pool is fixed at initialization). Hooks whose fill depends on per-swap `hookData` — e.g. `UniswapXAggregator`, which receives the signed order to fill — instead extend `BaseHookDataAggregator`. It mirrors `BaseAggregatorHook`'s `_beforeSwap`/settlement accounting but forwards `hookData` into a hookData-aware `_conductSwap(settle, take, params, poolId, hookData)`, so the data is read straight from calldata (no storage stash). Hooks that don't need `hookData` continue to extend `BaseAggregatorHook` directly and are unaffected.
