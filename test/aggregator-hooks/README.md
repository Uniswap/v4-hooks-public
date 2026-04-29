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
FOUNDRY_PROFILE=aggregator_hooks forge test --match-path "test/aggregator-hooks/*"
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

For tests that fork mainnet, you need an `.env` file containing pool info for each pool you want to test with.

Fork URLs and blocks are **chain-scoped** by chain id (same `.env` can fork Ethereum and Base without mixing blocks):

| Chain | RPC env | Optional pin |
|-------|---------|----------------|
| Ethereum mainnet (1) | `FORK_RPC_URL_1` | `FORK_BLOCK_NUMBER_1` (0 = latest) |
| Base (8453) | `FORK_RPC_URL_8453` | `FORK_BLOCK_NUMBER_8453` |

Fork suites read env vars only by chain id—there is no fallback to unsuffixed `FORK_RPC_URL` / `FORK_BLOCK_NUMBER`:

- **Ethereum mainnet (chain id 1):** **Fluid**, **StableSwap**, **StableSwap-NG**, **Uniswap V3** (`UniswapV3AggregatorForkTest`) use `FORK_RPC_URL_1` and optional `FORK_BLOCK_NUMBER_1` (0 = latest). The suite **skips** when `FORK_RPC_URL_1` is unset.
- **Base (8453):** only **Slipstream** (`SlipstreamAggregatorForkTest`) uses `FORK_RPC_URL_8453` and optional `FORK_BLOCK_NUMBER_8453`. The suite **skips** when `FORK_RPC_URL_8453` is unset.

Pool-specific overrides: `UNISWAP_V3_POOL_MANAGER` / `UNISWAP_V3_QUOTER_V2` (Ethereum) and `SLIPSTREAM_POOL_MANAGER` / `SLIPSTREAM_QUOTER_V2` (Base); each falls back to `POOL_MANAGER` / `QUOTER_V2` if unset.

See `.env.example` for keys. Example deployments (verify before production use):

| Role | Ethereum (Uni V3 fork) | Base (Slipstream fork) |
|------|-------------------------|-------------------------|
| PoolManager | `UNISWAP_V3_POOL_MANAGER` — e.g. `0x000000000004444c5dc75cB358380D2e3dE08A90` | `SLIPSTREAM_POOL_MANAGER` — e.g. `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Factory | `UNISWAP_V3_FACTORY` — `0x1F98431c8aD98523631ae4a59f267346ea31F984` | `SLIPSTREAM_FACTORY` — Slipstream **Pool factory** `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` (not the pool implementation) |
| Quoter | `UNISWAP_V3_QUOTER_V2` — `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` | `SLIPSTREAM_QUOTER_V2` — `0x254cF9E1E6e233aa1AC962CB9B05b2cfeAaE15b0` |
| External pool | `UNISWAP_V3_EXTERNAL_POOL` — e.g. WETH/USDT 0.3% `0x4e68Ccd3E89f51c3074ca5072bbac773960dFa36` (includes USDT) | `SLIPSTREAM_EXTERNAL_POOL` — any Slipstream pool, e.g. WETH/USDC `0xdbc6998296caA1652A810dc8D3BaF4A8294330f1` |

Example:

```
# Aggregator Hooks — chain forks
FORK_RPC_URL_1=
FORK_BLOCK_NUMBER_1=
FORK_RPC_URL_8453=
FORK_BLOCK_NUMBER_8453=
# UniswapV4 Pool Manager (required for many fork tests)
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
FLUID_DEX_T1_RESOLVER=
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
# Uniswap V3 fork (`test/aggregator-hooks/UniswapV3/`)
UNISWAP_V3_POOL_MANAGER=
UNISWAP_V3_FACTORY=
UNISWAP_V3_QUOTER_V2=
UNISWAP_V3_EXTERNAL_POOL=
QUOTER_V2=
# Slipstream fork (`test/aggregator-hooks/Slipstream/`)
SLIPSTREAM_POOL_MANAGER=
SLIPSTREAM_FACTORY=
SLIPSTREAM_QUOTER_V2=
SLIPSTREAM_EXTERNAL_POOL=
```
