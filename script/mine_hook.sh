#!/bin/bash

# Mine an aggregator hook address by searching with incrementing salt offsets

show_help() {
    echo "Mine an aggregator hook address by searching with incrementing salt offsets"
    echo ""
    echo "Usage: $0 <constructor_args> <protocol_id> [max_attempts] [deployer_address]"
    echo ""
    echo "Arguments:"
    echo "  constructor_args   Hex-encoded constructor arguments (e.g., 0x000000000000000000000000...)"
    echo "  protocol_id        Protocol identifier for the hook type:"
    echo "                       0xC1 - StableSwap"
    echo "                       0xC2 - StableSwap-NG"
    echo "                       0xF1 - FluidDexT1"
    echo "                       0xF2 - FluidDexV2 (not yet implemented)"
    echo "                       0xF3 - FluidDexLite"
    echo "                       0x71 - Tempo (TempoExchange)"
    echo "  max_attempts       Optional. Maximum mining attempts (default: 500)"
    echo "  deployer_address   Optional. Address that will deploy the hook."
    echo "                     Use factory address for factory deploys, wallet address for self-deploys."
    echo "                     (default: CREATE2_DEPLOYER 0x4e59b44847b379578588920cA78FbF26c0B4956C)"
    echo ""
    echo "Examples:"
    echo "  # Mine with default CREATE2_DEPLOYER"
    echo "  $0 0x00000000... 0xF3"
    echo ""
    echo "  # Mine with factory as deployer"
    echo "  $0 0x00000000... 0xF3 500 0xYourFactoryAddress"
    echo ""
    echo "  # Mine with wallet as deployer (for self-deploy)"
    echo "  $0 0x00000000... 0xF3 500 0xYourWalletAddress"
    echo ""
    echo "  # Mine Tempo aggregator (CONSTRUCTOR_ARGS = abi.encode(poolManager, tempoExchange))"
    echo "  $0 \$(cast abi-encode 'constructor(address,address)' \$POOL_MANAGER \$TEMPO_EXCHANGE) 0x71"
    echo ""
    echo "  # Find a different 0x71 salt (start searching from salt 20M)"
    echo "  INITIAL_SALT_OFFSET=20000000 $0 \$(cast abi-encode ...) 0x71 500"
    echo ""
    echo "Options:"
    echo "  -h, --help         Show this help message and exit"
    echo "  INITIAL_SALT_OFFSET  Env var: start mining from this salt (default 0). Use to find a different salt."
}

# Check for help flag
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

if [ $# -lt 2 ]; then
    echo "Error: Missing required arguments"
    echo ""
    show_help
    exit 1
fi

CONSTRUCTOR_ARGS=$1
PROTOCOL_ID=$2
MAX_ATTEMPTS=${3:-500}  # Default to 500 attempts
DEPLOYER_ADDRESS=${4:-0x4e59b44847b379578588920cA78FbF26c0B4956C}  # Default to CREATE2_DEPLOYER
SALT_INCREMENT=160444  # Must match MAX_LOOP in AggregatorHookMiner.sol

echo "Starting aggregator hook mining..."
echo "Constructor args: $CONSTRUCTOR_ARGS"
echo "Protocol ID: $PROTOCOL_ID"
echo "Deployer address: $DEPLOYER_ADDRESS"
echo "Max attempts: $MAX_ATTEMPTS"
echo "Salt increment per attempt: $SALT_INCREMENT"
echo ""

for ((i=0; i<MAX_ATTEMPTS; i++)); do
    OFFSET=$((i * SALT_INCREMENT))
    echo "Attempt $((i + 1))/$MAX_ATTEMPTS - Salt offset: $OFFSET"
    
    # Run the forge script and capture output
    OUTPUT=$(SALT_OFFSET=$OFFSET CONSTRUCTOR_ARGS=$CONSTRUCTOR_ARGS PROTOCOL_ID=$PROTOCOL_ID DEPLOYER=$DEPLOYER_ADDRESS forge script script/MineAggregatorHook.s.sol:MineAggregatorHookScript --via-ir 2>&1)
    
    # Check if we found a valid salt (look for "Hook Address" in output)
    if echo "$OUTPUT" | grep -q "Hook Address:"; then
        echo ""
        echo "SUCCESS! Found valid salt."
        echo ""
        echo "$OUTPUT" | grep -A 10 "=== Aggregator Hook Mining Results ==="
        exit 0
    fi
    
    # Check if it was a "could not find salt" error (expected, continue searching)
    if echo "$OUTPUT" | grep -q "could not find salt"; then
        echo "  No match found in this range, continuing..."
        continue
    fi
    
    # Some other error occurred
    echo "  Unexpected error:"
    echo "$OUTPUT"
    exit 1
done

echo ""
echo "FAILED: Could not find valid salt after $MAX_ATTEMPTS attempts"
echo "Total salts searched: $((MAX_ATTEMPTS * SALT_INCREMENT))"
exit 1
