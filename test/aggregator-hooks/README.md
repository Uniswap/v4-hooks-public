# aggregator-hooks

## Adding support for a new protocol

When adding a new protocol, the test suite must have the following:

- Unit tests giving 100% coverage
- Forked tests: tests ran on a forked version of the real, deployed protocol
- Fuzz tests 

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


## Testing (Fork Tests)

For tests that fork mainnet, you need an .env file containing pool info for each pool you want to test with.

Example:

```
MAINNET_RPC_URL=
# UniswapV4 Pool Manager (required for all tests)
POOL_MANAGER=
# StableSwap
STABLE_SWAP_POOL=
# StableSwap-NG
STABLE_SWAP_NG_POOL=
# Fluid DEX T1
FLUID_DEX_T1_POOL_ERC=
FLUID_DEX_T1_POOL_NATIVE=
# Fluid DEX Lite
FLUID_DEX_LITE=
FLUID_DEX_LITE_RESOLVER=
FLUID_DEX_LIT_ADMIN_MODULE=
FLUID_DEX_LITE_TOKEN0_ERC=
FLUID_DEX_LITE_TOKEN1_ERC=
FLUID_DEX_LITE_SALT_ERC=
FLUID_DEX_LITE_LIQUIDITY=
```