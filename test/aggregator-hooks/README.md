# aggregator-hooks

## Fuzz Testing (StableSwapNG)

The StableSwapNG fuzz tests deploy Curve pools locally using precompiled bytecode.

### Precompiled Bytecode

The fuzz tests use precompiled bytecode stored in `test/aggregator-hooks/StableSwapNG/precompiled/`:

- `StableSwapNGFactory.bin` - Factory contract (from `0x6A8cbed756804B16E05E741eDaBd5cB544AE21bf` on Mainnet Ethereum)
- `StableSwapNGPool.bin` - Plain AMM pool implementation (from `0xDCc91f930b42619377C200BA05b7513f2958b202` on Mainnet Ethereum)
- `StableSwapNGMath.bin` - Math library (from `0xc9CBC565A9F4120a2740ec6f64CC24AeB2bB3E5E` on Mainnet Ethereum)
- `StableSwapNGViews.bin` - Views contract (from `0xFF53042865dF617de4bB871bD0988E7B93439cCF` on Mainnet Ethereum)


## Testing (Fork Tests)

For tests that fork mainnet, you need an .env file containing pool info for each pool you want to test with.

Example:

```
MAINNET_RPC_URL=<RPC_URL>
# UniswapV4 Pool Manager (required for all tests)
POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90
# StableSwap
STABLE_SWAP_POOL=0xf2DCf6336D8250754B4527f57b275b19c8D5CF88
# StableSwap-NG
STABLE_SWAP_NG_POOL=0x383E6b4437b59fff47B619CBA855CA29342A8559
# Fluid DEX T1
FLUID_DEX_T1_POOL_ERC=0xdE632C3a214D5f14C1d8ddF0b92F8BCd188fee45
FLUID_DEX_T1_POOL_NATIVE=0x0B1a513ee24972DAEf112bC777a5610d4325C9e7
# Fluid DEX Lite
FLUID_DEX_LITE=0xBbcb91440523216e2b87052A99F69c604A7b6e00
FLUID_DEX_LITE_RESOLVER=0x26b696D0dfDAB6c894Aa9a6575fCD07BB25BbD2C
FLUID_DEX_LITE_TOKEN0_ERC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
FLUID_DEX_LITE_TOKEN1_ERC=0xdAC17F958D2ee523a2206206994597C13D831ec7
FLUID_DEX_LITE_SALT_ERC=0x0000000000000000000000000000000000000000000000000000000000000000
```