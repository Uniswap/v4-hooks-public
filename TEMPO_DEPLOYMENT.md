# Tempo Exchange Aggregator Hook - Testnet Deployment

## Deployment Summary

**Network**: Tempo Testnet
**Chain ID**: 42431
**RPC**: https://rpc.moderato.tempo.xyz
**Deployer**: 0xF7E710bD4BDe2190f02CD16a777680a06E87BebF

## Deployed Contracts

### Core Infrastructure
- **PoolManager**: `0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2`
- **TempoExchange (Mock)**: `0x469c9e7A307bde9d7A7a4199b722A8a7da291cE6`
- **Factory**: `0x4046D12D3fC48dD7c35FB9cfA20C7c2Cf6FF85b7`
- **Hook**: `0x122771c9AA343E4d35a794258aA32fE463c46088`

### Test Tokens
- **Token0 (aUSD)**: `0x8977049D59bb942b82Ed4BeC47E60ba1ADF1dCf0`
- **Token1 (bUSD)**: `0x8aD2892E8B91A0832b50CfBF2c7DBe6E9875025a`

### Pool Configuration
- **Pool ID**: `0xcf5687fc01cf2a20c6596c2cc7176b44039e8aa66bec9783b63a7527f2a15557`
- **Fee**: 0.05% (500)
- **Tick Spacing**: 10
- **Initial Price**: 1:1

## Deployment Details

The deployment used HookMiner to find a valid hook address with the required flags:
- `BEFORE_SWAP_FLAG`
- `BEFORE_SWAP_RETURNS_DELTA_FLAG`
- `BEFORE_INITIALIZE_FLAG`

**Salt**: `0x00000000000000000000000000000000000000000000000000000000000013d8`

## Test Results

All tests passed successfully:

### 1. Pseudo Total Value Locked
```bash
cast call 0x122771c9AA343E4d35a794258aA32fE463c46088 \
  "pseudoTotalValueLocked(bytes32)(uint256,uint256)" \
  0xcf5687fc01cf2a20c6596c2cc7176b44039e8aa66bec9783b63a7527f2a15557 \
  --rpc-url https://rpc.moderato.tempo.xyz
```
**Result**: 100,000,000 tokens (100M with 6 decimals) in each token

### 2. Quote - Exact Input
**Test**: Swap 1,000 aUSD for bUSD
```bash
cast call 0x122771c9AA343E4d35a794258aA32fE463c46088 \
  "quote(bool,int256,bytes32)(uint256)" \
  true -1000000000 \
  0xcf5687fc01cf2a20c6596c2cc7176b44039e8aa66bec9783b63a7527f2a15557 \
  --rpc-url https://rpc.moderato.tempo.xyz
```
**Result**: 999 bUSD (0.1% fee applied correctly)

### 3. Quote - Exact Output
**Test**: Get required input to receive 500 bUSD
```bash
cast call 0x122771c9AA343E4d35a794258aA32fE463c46088 \
  "quote(bool,int256,bytes32)(uint256)" \
  true 500000000 \
  0xcf5687fc01cf2a20c6596c2cc7176b44039e8aa66bec9783b63a7527f2a15557 \
  --rpc-url https://rpc.moderato.tempo.xyz
```
**Result**: ~500.5 aUSD required (fee included)

### 4. Token Configuration
Both tokens correctly registered:
- Token0: 0x8977049D59bb942b82Ed4BeC47E60ba1ADF1dCf0 ✓
- Token1: 0x8aD2892E8B91A0832b50CfBF2c7DBe6E9875025a ✓

### 5. Liquidity Check
TempoExchange funded with:
- Token0 (aUSD): 100,000,000 tokens ✓
- Token1 (bUSD): 100,000,000 tokens ✓

## Contract Behavior Verification

The deployed hook successfully demonstrates:

1. **Initialization**: Pool initialized with hook at correct address with required flags
2. **Quote Function**: Returns accurate quotes for both exact-input and exact-output swaps
3. **Fee Application**: Correctly applies 0.1% fee in MockTempoExchange
4. **Liquidity Visibility**: Exposes TempoExchange liquidity via pseudoTotalValueLocked
5. **Token Validation**: Validates supported tokens during initialization

## Next Steps for Production

To deploy with the real Tempo Exchange precompile:

1. **Find TempoExchange Address**: Identify the actual precompiled contract address on Tempo
2. **Update Environment**:
   ```bash
   export TEMPO_EXCHANGE=<actual_precompile_address>
   ```
3. **Deploy Factory**:
   ```bash
   forge script script/DeployTempoAggregator.s.sol \
     --rpc-url tempo_testnet \
     --broadcast \
     --legacy
   ```
4. **Create Production Pool**: Use the factory to create a pool with real stablecoin pairs

## Testing Commands

Quick reference for testing:

```bash
# Environment
export HOOK=0x122771c9AA343E4d35a794258aA32fE463c46088
export POOL_ID=0xcf5687fc01cf2a20c6596c2cc7176b44039e8aa66bec9783b63a7527f2a15557
export RPC=https://rpc.moderato.tempo.xyz

# Check TVL
cast call $HOOK "pseudoTotalValueLocked(bytes32)(uint256,uint256)" $POOL_ID --rpc-url $RPC

# Quote swap (exact input: -1000 tokens)
cast call $HOOK "quote(bool,int256,bytes32)(uint256)" true -1000000000 $POOL_ID --rpc-url $RPC

# Quote swap (exact output: 500 tokens)
cast call $HOOK "quote(bool,int256,bytes32)(uint256)" true 500000000 $POOL_ID --rpc-url $RPC
```

## Deployment Artifacts

- Script: `script/DeployTempoTestEnvironment.s.sol`
- Broadcast logs: `broadcast/DeployTempoTestEnvironment.s.sol/42431/`
- Gas used: ~16.2M gas (~0.162 ETH at 10 gwei)

## Notes

- This deployment uses a **MockTempoExchange** for testing purposes
- The mock implements the ITempoExchange interface with a 0.1% fee
- For production, replace with the actual Tempo precompiled contract address
- All contracts compiled with Solidity 0.8.26, via-ir optimization enabled
- Hook address mined using CREATE2 to meet Uniswap v4 flag requirements
