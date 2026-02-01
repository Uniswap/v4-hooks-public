# Tempo Exchange Aggregator Hook - Production Deployment

## Deployment Summary

**Network**: Tempo Testnet (Moderato)
**Chain ID**: 42431
**RPC**: https://rpc.moderato.tempo.xyz
**Deployer**: 0xF7E710bD4BDe2190f02CD16a777680a06E87BebF

## Deployed Contracts (Production)

### Core Infrastructure
- **PoolManager**: `0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2`
- **TempoExchange (Real Precompile)**: `0xDEc0000000000000000000000000000000000000`
- **TempoExchangeAggregatorFactory**: `0x9D101e3c30ccF04ddE513f1687CB446E797ab735`

### Factory Verification

✅ Factory successfully deployed and connected to real TempoExchange precompile

```bash
cast call 0x9D101e3c30ccF04ddE513f1687CB446E797ab735 \
  "POOL_MANAGER()(address)" \
  --rpc-url https://rpc.moderato.tempo.xyz
# Returns: 0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2

cast call 0x9D101e3c30ccF04ddE513f1687CB446E797ab735 \
  "TEMPO_EXCHANGE()(address)" \
  --rpc-url https://rpc.moderato.tempo.xyz
# Returns: 0xDEc0000000000000000000000000000000000000
```

## Test Deployment (with MockTempoExchange)

For comprehensive testing without requiring real Tempo stablecoins:

### Test Environment Contracts
- **PoolManager**: `0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2` (same as production)
- **MockTempoExchange**: `0x469c9e7A307bde9d7A7a4199b722A8a7da291cE6`
- **Test Factory**: `0x4046D12D3fC48dD7c35FB9cfA20C7c2Cf6FF85b7`
- **Test Hook**: `0x122771c9AA343E4d35a794258aA32fE463c46088`

### Test Tokens (6 decimals)
- **aUSD**: `0x8977049D59bb942b82Ed4BeC47E60ba1ADF1dCf0`
- **bUSD**: `0x8aD2892E8B91A0832b50CfBF2c7DBe6E9875025a`

### Test Results

All functionality verified with MockTempoExchange:

✅ **pseudoTotalValueLocked()** - Returns liquidity correctly
✅ **quote() - Exact Input** - 1,000 → 999 tokens (0.1% fee)
✅ **quote() - Exact Output** - 500 output requires ~500.5 input
✅ **Token Configuration** - Validates and registers tokens
✅ **Pool Initialization** - Successfully creates pools via factory

## Production Usage

### Prerequisites

To use the production factory with real TempoExchange, you need:

1. **Registered Stablecoins**: The TempoExchange precompile only accepts specific registered stablecoins
2. **Token Addresses**: You must use the actual Tempo stablecoin addresses

### Finding Supported Stablecoins

The TempoExchange at `0xDEc0000000000000000000000000000000000000` is a precompiled contract that validates tokens. Random ERC20 tokens will be rejected with `TokensNotSupported` error.

**To find supported stablecoins:**
- Check Tempo documentation: https://docs.tempo.xyz/protocol/exchange/spec
- Contact Tempo team for list of registered stablecoins
- Check Tempo block explorer for existing DEX transactions

### Creating a Pool (Once You Have Stablecoin Addresses)

```bash
# Set environment variables
export TEMPO_TESTNET_PRIVATE_KEY=<your_private_key>
export TEMPO_TOKEN0=<registered_stablecoin_1>
export TEMPO_TOKEN1=<registered_stablecoin_2>

# Run deployment script
forge script script/CreateTempoPool.s.sol \
  --rpc-url tempo_testnet \
  --broadcast \
  --legacy
```

The factory will:
1. Mine a valid hook address with required flags
2. Deploy the hook via CREATE2
3. Initialize a Uniswap V4 pool
4. Register the tokens with the hook

## Architecture

### TempoExchangeAggregator Hook

The hook implements the ExternalLiqSourceHook pattern:

1. **beforeInitialize**: Validates tokens are supported by TempoExchange
2. **beforeSwap**: Routes swaps through TempoExchange for optimal execution
3. **quote**: Provides accurate price quotes from TempoExchange
4. **pseudoTotalValueLocked**: Exposes TempoExchange liquidity

### Required Hook Flags

- `BEFORE_SWAP_FLAG`: Intercepts swap calls
- `BEFORE_SWAP_RETURNS_DELTA_FLAG`: Returns custom swap amounts
- `BEFORE_INITIALIZE_FLAG`: Validates tokens during pool setup

### Factory Benefits

Using the factory ensures:
- Correct hook address via CREATE2 mining
- Proper flag configuration
- Atomic deployment + pool initialization
- Consistent deployment across environments

## Testing Commands

### Test with MockTempoExchange

```bash
export HOOK=0x122771c9AA343E4d35a794258aA32fE463c46088
export POOL_ID=0xcf5687fc01cf2a20c6596c2cc7176b44039e8aa66bec9783b63a7527f2a15557
export RPC=https://rpc.moderato.tempo.xyz

# Check liquidity
cast call $HOOK "pseudoTotalValueLocked(bytes32)(uint256,uint256)" $POOL_ID --rpc-url $RPC

# Get quote for 1000 token swap
cast call $HOOK "quote(bool,int256,bytes32)(uint256)" true -1000000000 $POOL_ID --rpc-url $RPC
```

### Verify Production Factory

```bash
export FACTORY=0x9D101e3c30ccF04ddE513f1687CB446E797ab735
export RPC=https://rpc.moderato.tempo.xyz

# Check configuration
cast call $FACTORY "POOL_MANAGER()(address)" --rpc-url $RPC
cast call $FACTORY "TEMPO_EXCHANGE()(address)" --rpc-url $RPC

# Compute hook address for a salt
cast call $FACTORY "computeAddress(bytes32)(address)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  --rpc-url $RPC
```

## Contract Verification

### What Was Tested

✅ Factory deployment with real TempoExchange
✅ Factory state (PoolManager and TempoExchange addresses)
✅ Hook address computation via factory
✅ Full swap functionality (with MockTempoExchange)
✅ Quote accuracy for both swap directions
✅ Liquidity visibility
✅ Token validation

### What Requires Real Stablecoins

⚠️ Pool creation with production TempoExchange
⚠️ Actual swaps through real precompile
⚠️ Integration with Tempo's stablecoin liquidity

The production factory is ready and will work as soon as you provide registered Tempo stablecoin addresses.

## Deployment Scripts

- **Production Factory**: `script/DeployTempoAggregator.s.sol`
- **Pool Creation**: `script/CreateTempoPool.s.sol`
- **Test Environment**: `script/DeployTempoTestEnvironment.s.sol`
- **Network Check**: `script/CheckTempoNetwork.s.sol`

## Gas Costs

- **Factory Deployment**: ~3.3M gas (~0.033 ETH at 10 gwei)
- **Hook + Pool Creation**: ~16.2M gas (~0.162 ETH at 10 gwei)

## Next Steps

1. **Obtain Stablecoin Addresses**: Get list of registered Tempo stablecoins
2. **Create Production Pool**: Use `CreateTempoPool.s.sol` with real token addresses
3. **Test Swaps**: Execute actual swaps through the hook
4. **Monitor Performance**: Compare Tempo DEX vs Uniswap pricing
5. **Deploy Additional Pools**: Create multiple trading pairs as needed

## Important Notes

- TempoExchange uses **6 decimals** for all stablecoins
- TempoExchange uses **uint128** for amounts (hook handles conversion)
- Only **registered stablecoins** can be used with the precompile
- Hook address must have correct flags (factory handles this)
- All contracts compiled with Solidity 0.8.26 + via-ir optimization

## Support

For questions about:
- Tempo stablecoins: https://docs.tempo.xyz
- Uniswap V4 hooks: https://docs.uniswap.org
- This implementation: Check the test files in `test/aggregator-hooks/TempoExchange/`
