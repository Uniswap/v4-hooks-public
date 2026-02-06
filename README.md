## v4-hooks-internal

Uniswap v4 hook contracts

### Hooks

| Hook                                                | Description                                                                                | Documentation                                        |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| [StableStableHook](src/stable/StableStableHook.sol) | Dynamic fee hook for stable/stable pools with optimal range pricing and time-decaying fees | [docs/StableStableHook.md](docs/StableStableHook.md) |
| [WETHHook](src/WETHHook.sol)                        | Token wrapper hook for WETH                                                                | —                                                    |
| [WstETHHook](src/WstETHHook.sol)                    | Token wrapper hook for WstETH                                                              | —                                                    |
| [WstETHRoutingHook](src/WstETHRoutingHook.sol)      | Routing hook for WstETH                                                                    | —                                                    |

#### Table of Contents

- [Setup](#setup)
- [Deployment](#deployment)
- [Docs](#docs)
- [Contributing](#contributing)

## Setup

Follow these steps to set up your local environment:

- [Install foundry](https://book.getfoundry.sh/getting-started/installation)
- Install dependencies: `forge install`
- Build contracts: `forge build`
- Test contracts: `forge test`

If you intend to develop on this repo, follow the steps outlined in [CONTRIBUTING.md](CONTRIBUTING.md#install).

## Deployment

This repo utilizes versioned deployments. For more information on how to use forge scripts within the repo, check [here](CONTRIBUTING.md#deployment).

Smart contracts are deployed or upgraded using the following command:

```shell
forge script script/Deploy.s.sol --broadcast --rpc-url <rpc_url> --verify
```

## Docs

The documentation and architecture diagrams for the contracts within this repo can be found [here](docs/).
Detailed documentation generated from the NatSpec documentation of the contracts can be found [here](docs/autogen/src/src/).
When exploring the contracts within this repository, it is recommended to start with the interfaces first and then move on to the implementation as outlined [here](CONTRIBUTING.md#natspec--comments)

## Contributing

If you want to contribute to this project, please check [CONTRIBUTING.md](CONTRIBUTING.md) first.
