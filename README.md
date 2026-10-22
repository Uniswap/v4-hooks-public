## Uniswap V4 Hooks

This repository contains the official Uniswap v4 hook contracts developed and maintained by Uniswap Labs. New hooks will be added to this repository as they are built and audited.

## Table of Contents

- [Overview](#overview)
- [Hooks](#hooks)
- [Installation](#installation)
- [Deployments](#deployments)
- [Audits](#audits)
- [Docs](#docs)
- [Contributing](#contributing)
- [License](#license)

## Overview

[Hooks](https://docs.uniswap.org/contracts/v4/concepts/hooks) are external contracts that can be attached to Uniswap V4 pools to customize their behavior at key points in the pool lifecycle. This repository houses all Uniswap hook implementations built on top of v4-core.

## Hooks

| Hook                                            | Description                                                                                                                           |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| [StablePairHook](src/stable/StablePairHook.sol) | Dynamic fee hook for pools of two assets expected to hold the same price, with optimal range pricing and time-decaying fees           |
| [WETHHook](src/WETHHook.sol)                    | Wraps ETH to WETH and unwraps WETH to ETH through a Uniswap v4 pool at a 1:1 rate with zero fees                                      |
| [WstETHHook](src/WstETHHook.sol)                | Wraps stETH to wstETH and back through a Uniswap v4 pool, handling the dynamic exchange rate and rebasing rounding errors             |
| [WstETHRoutingHook](src/WstETHRoutingHook.sol)  | Companion to `WstETHHook` that enables swap simulation via the V4 Quoter, computing wrapping output without executing token transfers |

<details>
<summary><a href="src/ERC4626WrapperHook.sol">ERC4626WrapperHook</a></summary>

A generic exact-input hook for exchanging an ERC-4626 vault's underlying asset and shares through a zero-fee Uniswap v4 pool. It accounts for rebasing transfer rounding and rejects liquidity additions.

</details>

<details>
<summary><a href="src/ERC4626RoutingHook.sol">ERC4626RoutingHook</a></summary>

A companion hook that uses ERC-4626 preview functions to simulate wrapper-hook swaps through the V4 Quoter.

</details>

## Installation

```bash
forge install
forge build
forge test --isolate
```

## Deployments

### WETHHook

| Network  | Address                                    | Commit Hash |
| -------- | ------------------------------------------ | ----------- |
| Ethereum | 0x57991106cb7aa27e2771beda0d6522f68524a888 | c797b9e     |
| Unichain | 0x730b109bad65152c67ecc94eb8b0968603dba888 | c797b9e     |
| Optimism | 0x480dafdb4d6092ef3217595b75784ec54b52e888 | c797b9e     |
| Base     | 0xb08211d57032dd10b1974d4b876851a7f7596888 | c797b9e     |
| Arbitrum | 0x2a4adf825bd96598487dbb6b2d8d882a4eb86888 | c797b9e     |
| Monad    | 0x3fad8a7205f943528915e67cf94fc792c8fce888 | efab318     |

### WstETHHook

| Network  | Address                                    | Commit Hash |
| -------- | ------------------------------------------ | ----------- |
| Ethereum | 0xcdde8f9c3414a00f804e5c565eed9949ad17e888 | 320811c     |

### WstETHRoutingHook

| Network  | Address                                    | Commit Hash |
| -------- | ------------------------------------------ | ----------- |
| Ethereum | 0x3ac6e14a142251eb3fe739399e0a8da81ed06888 | 320811c     |

### StablePairHook

The registered v4 hook is the ERC1967 proxy — its address is permanent and carries the hook flags.
The implementation behind it changes on UUPS upgrades, so the implementation column reflects the
current implementation as of the listed commit.

| Network  | Proxy (hook)                               | Implementation                             | Commit Hash | Date       |
| -------- | ------------------------------------------ | ------------------------------------------ | ----------- | ---------- |
| Ethereum | 0x0000113dCf4ADd69999Fad8F20F2b63F979bfcC0 | 0x5f216d21b1C81346938EDDc1Df7e0111A0F64000 | ecb8c96     | 2026-07-27 |
| Arbitrum | 0x630e9CaC0ffF557Bd3A01DAa111ed253c771Bcc0 | 0x424e2f8D89eeaB51AF10669D149Fbd4BEB090000 | ecb8c96     | 2026-10-05 |
| X Layer  | 0x630e9CaC0ffF557Bd3A01DAa111ed253c771Bcc0 | 0x424e2f8D89eeaB51AF10669D149Fbd4BEB090000 | ecb8c96     | 2026-10-20 |
| Sepolia  | 0x2F45A94782d3e187BaB5F72448bb85d6d1d67CC0 | 0xDBc81fFadaB5ee9c9fB1c2D43Bef547EB9c64000 | 7abd34b     | 2026-07-22 |

`owner` and `configManager` are the [Uniswap Governance Timelock](https://etherscan.io/address/0x1a9C8182C09F50C8318d769245beA52c32BE35BC),
so fee-config changes and implementation upgrades go through a governance proposal.
On Arbitrum and X Layer they are the Timelock's L1-to-L2 alias `0x2BAD8182C09F50c8318d769245beA52C32Be46CD`
([Arbiscan](https://arbiscan.io/address/0x2BAD8182C09F50c8318d769245beA52C32Be46CD), [OKLink](https://www.oklink.com/x-layer/address/0x2BAD8182C09F50c8318d769245beA52C32Be46CD)),
so the same governance proposals reach them through each chain's bridge.
On Sepolia, `owner`, `poolInitializer` and `configManager` are all the test deployer
`0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95`.

On Robinhood Chain only the implementation is deployed, at `0xaF7895228C7E5ea4FA60d6CB7E42eedC99e94000`
(commit ecb8c96)

#### Pools

Pools initialized on the StablePairHook, on each network's hook from the table above. Every pool uses the
dynamic-fee flag (`0x800000`) and a `tickSpacing` of 1, so the pool ID is `keccak256(abi.encode(PoolKey))`
over the values below.

| Network  | Pool       | Currency0                                         | Currency1                                          | Pool ID                                                            | Date       |
| -------- | ---------- | ------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------ | ---------- |
| Ethereum | USDC/USDT  | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | USDT `0xdAC17F958D2ee523a2206206994597C13D831ec7`  | 0x2b21c65d9a7dc6926ee330a1c6e5a8037fd81774f3dc066536f800128e39f634 | 2026-09-10 |
| Ethereum | USDC/USDG  | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | USDG `0xe343167631d89B6Ffc58B88d6b7fB0228795491D`  | 0xeda62d2906d0edf26d40c793d581609552a44a87f618a98ff76ebe8dde4b7edb | 2026-09-10 |
| Arbitrum | USDG/USDC  | USDG `0x004B506865409877C9fA29bfb1ebA929984B9bbC` | USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`  | 0x52b42d5f1e4a0d4bce86667bb069cf257e512d98ce617f549f6e4fbb0bee41e6 | 2026-10-05 |
| X Layer  | USDG/USDT0 | USDG `0x4ae46a509F6b1D9056937BA4500cb143933D2dc8` | USDT0 `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | 0x472a136cc430cb6fc27870fe8e973a2891abc619752fabbdc4d78cf887cd0851 | 2026-10-21 |
| X Layer  | USDC/USDT0 | USDC `0x74b7F16337b8972027F6196A17a631aC6dE26d22` | USDT0 `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | 0x0527dced3a892ab920c9d890034e6780ad8a74f8463f95c2a2a4fcdc600af695 | 2026-10-21 |
| X Layer  | USDG/USDC  | USDG `0x4ae46a509F6b1D9056937BA4500cb143933D2dc8` | USDC `0x74b7F16337b8972027F6196A17a631aC6dE26d22`  | 0x7507fe799c15cb2ba2862a42d1497c96a2e2e61b38a6f2e80a19bb983f5d37ae | 2026-10-21 |

### VolatilePairHook

Same proxy layout as `StablePairHook`: the ERC1967 proxy is the registered v4 hook and the
implementation column reflects the current implementation as of the listed commit.

| Network  | Proxy (hook)                               | Implementation                             | Commit Hash | Date       |
| -------- | ------------------------------------------ | ------------------------------------------ | ----------- | ---------- |
| Ethereum | 0x000022Ec4eBD6b12294396E852E4C3876b253Cc0 | 0x1DDbf7215be4F8A7623B9B1B0255C6e1E3F6c000 | a053a88     | 2026-10-13 |
| Sepolia  | 0x6B1DF823F9492000cC6Bc8dB2c1714E767DaFCc0 | 0x01C274A3Ea7CdA08c90140395349004cEf28C000 | ba9a531     | 2026-10-13 |

On Ethereum, `owner` and `configManager` are the [Uniswap Governance Timelock](https://etherscan.io/address/0x1a9C8182C09F50C8318d769245beA52c32BE35BC),
so fee-config changes and implementation upgrades go through a governance proposal. `poolInitializer`
is the Labs Safe `0xFc43582532E90Fa8726FE9cdb5FAd48f4e487d27`.

On Sepolia, `owner`, `poolInitializer` and `configManager` are all the test deployer
`0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95`.

#### Pools

Pools initialized on the Ethereum hook. Every pool uses the dynamic-fee flag (`0x800000`) and a
`tickSpacing` of 4, so the pool ID is `keccak256(abi.encode(PoolKey))` over the values below.

| Pool     | Currency0                                        | Currency1                                         | Pool ID                                                            | Date       |
| -------- | ------------------------------------------------ | ------------------------------------------------- | ------------------------------------------------------------------ | ---------- |
| ETH/USDC | ETH `0x0000000000000000000000000000000000000000` | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 0x98316e8405502774a5d0a0761276b5d26505a8195c1905169864008d5e7a3eea | 2026-10-13 |

## Audits

| Name           | Date       | Report                                                     |
| -------------- | ---------- | ---------------------------------------------------------- |
| WETHHook       | 04/24/2025 | [OpenZeppelin](./docs/audits/openzeppelin-weth-wsteth.pdf) |
| WstETHHook     | 04/24/2025 | [OpenZeppelin](./docs/audits/openzeppelin-weth-wsteth.pdf) |
| StablePairHook | 03/02/2026 | [OpenZeppelin](./docs/audits/openzeppelin-stablepair.pdf)  |

### Security Contact

[security@uniswap.org](mailto:security@uniswap.org)

## Docs

The documentation and architecture diagrams for the contracts within this repo can be found [here](docs/).
Detailed documentation generated from the NatSpec documentation of the contracts can be found [here](docs/autogen/src/pages/src/).
When exploring the contracts within this repository, it is recommended to start with the interfaces first and then move on to the implementation as outlined [here](CONTRIBUTING.md#natspec--comments).

## Repository Structure

All contracts are located in the `src/` directory. `test/` contains unit and fork tests for the hook contracts.

```
src/
----base/
|   BaseHook.sol
|   BaseTokenWrapperHook.sol
----interfaces/
|   IWstETH.sol
----utils/
|   HookMiner.sol
----ERC4626RoutingHook.sol
----ERC4626WrapperHook.sol
----WETHHook.sol
----WstETHHook.sol
----WstETHRoutingHook.sol
test/
----mocks/
----shared/
----ERC4626WrapperHook.t.sol
----ERC4626WrapperHook.fork.t.sol
----ERC4626WrapperHookInvariant.t.sol
----WETHHook.t.sol
----WstETHHook.t.sol
----WstETHHook.fork.t.sol
```

## Contributing

If you want to contribute to this project, please check [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

The contracts are covered under the MIT License (`MIT`), see [LICENSE](LICENSE).
