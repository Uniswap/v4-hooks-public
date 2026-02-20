# aggregator-hooks

## Adding support for a new protocol

When adding a new protocol, the test suite must have the following:

- Unit tests giving 100% coverage
- Forked tests: tests ran on a forked version of the real, deployed protocol
- Fuzz tests

Note: Fork tests must be ran on a USDT pool atleast once (since USDT has slightly different behavior than other tokens).

## Testing

Aggregator Hook tests must be ran with the following command:

```bash
FOUNDRY_PROFILE=aggregator_hooks forge test --match-path "test/aggregator-hooks/*" --skip src/stable/*
```

### Fuzz Testing (Curve pools)

The StableSwapNG/StableSwap fuzz tests deploy Curve pools locally using precompiled bytecode.

#### Precompiled Bytecode

The fuzz tests use precompiled bytecode stored in `test/aggregator-hooks/StableSwapNG/precompiled/`:

- `StableSwapNGFactory.bin` - Factory contract (from `0x6A8cbed756804B16E05E741eDaBd5cB544AE21bf` on Mainnet Ethereum)
- `StableSwapNGPool.bin` - Plain AMM pool implementation (from `0xDCc91f930b42619377C200BA05b7513f2958b202` on Mainnet Ethereum)
- `StableSwapNGMath.bin` - Math library (from `0xc9CBC565A9F4120a2740ec6f64CC24AeB2bB3E5E` on Mainnet Ethereum)
- `StableSwapNGViews.bin` - Views contract (from `0xFF53042865dF617de4bB871bD0988E7B93439cCF` on Mainnet Ethereum)

### Tempo (Integration Tests)

Tempo is a separate EVM-compatible chain with an enshrined stablecoin DEX implemented as a precompiled contract (`0xDEc0...`). Standard `forge test` and `forge script` cannot be used for integration testing because Foundry's local EVM does not support Tempo's custom precompiles — calls to precompiled addresses fail with `OpcodeNotFound`. Fork testing is also not possible since Tempo is its own chain, not an Ethereum L1/L2.

Unit tests (`TempoExchangeTest.t.sol`) use mock contracts to test hook logic locally. For on-chain integration tests, a bash script using `cast` sends transactions directly to the Tempo chain:

```bash
HOOK_ADDRESS=0x... ROUTER_ADDRESS=0x... TEMPO_TOKEN_0=0x... TEMPO_TOKEN_1=0x... \
  ./test/aggregator-hooks/TempoExchange/test_tempo_aggregator.sh
```

### Fuzz Testing (Fluid pools)

The FluidDexLite/FluidDexT1 fuzz tests use pre-deployed infrastructure on forked versions of chains where the respective Fluid Dex infrastructure is already deployed. This is because adding aggregator-hook tests on top of Fluid's infrastructure deployment scripts cause multiple compilation issues, including memory/stack/depth issues, even with --via-ir. Everything else (pools, liquidity positions, tokens, etc) is bespokely created in the test.

## Testing (Fork Tests)

For tests that fork mainnet, you need an .env file containing pool info for each pool you want to test with.

Example:

```
# Aggregator Hooks:
FORK_RPC_URL=
# UniswapV4 Pool Manager (required for all tests)
POOL_MANAGER=
# StableSwap
STABLE_SWAP_POOL=
# StableSwap-NG
STABLE_SWAP_NG_POOL=
# Fluid
FLUID_LIQUIDITY=
# Fluid DEX T1
FLUID_DEX_T1_POOL_ERC=
FLUID_DEX_T1_POOL_NATIVE=
FLUID_DEX_T1_RESOLVER=;
FLUID_DEX_T1_FACTORY=
FLUID_DEX_T1_DEPLOYMENT_LOGIC=
FLUID_DEX_T1_TIMELOCK=
# Fluid DEX Lite
FLUID_DEX_LITE=
FLUID_DEX_LITE_RESOLVER=
FLUID_DEX_LITE_ADMIN_MODULE=
FLUID_DEX_LITE_AUTH=
FLUID_DEX_LITE_TOKEN0_ERC20=
FLUID_DEX_LITE_TOKEN1_ERC20=
FLUID_DEX_LITE_SALT_ERC20=
```
