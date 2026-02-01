#!/bin/bash
set -e

# Check if private key is set
if [ -z "$TEMPO_TESTNET_PRIVATE_KEY" ]; then
  echo "Error: TEMPO_TESTNET_PRIVATE_KEY environment variable not set"
  echo "Please set it with: export TEMPO_TESTNET_PRIVATE_KEY=<your_private_key>"
  exit 1
fi

export DEPLOYER=0xF7E710bD4BDe2190f02CD16a777680a06E87BebF
export FACTORY=0x9D101e3c30ccF04ddE513f1687CB446E797ab735
export POOL_MANAGER=0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2
export TEMPO_EXCHANGE=0xDEc0000000000000000000000000000000000000
export TOKEN0=0x20C0000000000000000000000000000000000000
export TOKEN1=0x20C0000000000000000000000000000000000001
export RPC=https://rpc.moderato.tempo.xyz

echo "=== DEPLOYING TEMPO PRODUCTION POOL ==="
echo "Factory: $FACTORY"
echo "Token0 (pathUSD): $TOKEN0"
echo "Token1 (AlphaUSD): $TOKEN1"
echo ""

# First, let's compute what salt we need
echo "Computing required salt for valid hook address..."
# We'll use a pre-computed salt that works
SALT=0x0000000000000000000000000000000000000000000000000000000000001076

echo "Using salt: $SALT"
echo ""

# Compute expected hook address
echo "Computing expected hook address..."
HOOK_ADDRESS=$(cast call $FACTORY "computeAddress(bytes32)(address)" $SALT --rpc-url $RPC)
echo "Expected hook address: $HOOK_ADDRESS"
echo ""

# Try to create the pool
echo "Attempting to create pool..."
cast send $FACTORY \
  "createPool(bytes32,address,address,uint24,int24,uint160)(address)" \
  $SALT \
  $TOKEN0 \
  $TOKEN1 \
  500 \
  10 \
  79228162514264337593543950336 \
  --private-key $TEMPO_TESTNET_PRIVATE_KEY \
  --rpc-url $RPC \
  --legacy || {
    echo "Pool creation failed - checking if it's a simulation issue..."
    echo "Trying to check if hook was already deployed..."
    cast code $HOOK_ADDRESS --rpc-url $RPC
}

