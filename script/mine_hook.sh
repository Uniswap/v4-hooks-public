#!/bin/bash

# Mine an aggregator hook address by searching with incrementing salt offsets
# Usage: ./script/mine_hook.sh <constructor_args> <protocol_id> [max_attempts]
#   constructor_args: Hex-encoded constructor arguments (e.g., 0x000000000000000000000000...)
#   protocol_id: Protocol identifier (0xC1 for StableSwap, 0xC2 for StableSwap-NG, 0xF1 for FluidDexT1, 0xF2 for FluidDexV2, 0xF3 for FluidDexLite)
#   max_attempts: Optional, defaults to 500

if [ $# -lt 2 ]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 <constructor_args> <protocol_id> [max_attempts]"
    echo "  constructor_args: Hex-encoded constructor arguments (e.g., 0x000000000000000000000000...)"
    echo "  protocol_id: Protocol identifier (0xC1, 0xC2, 0xF1, 0xF2, 0xF3)"
    echo "  max_attempts: Optional, defaults to 500"
    exit 1
fi

CONSTRUCTOR_ARGS=$1
PROTOCOL_ID=$2
MAX_ATTEMPTS=${3:-500}  # Default to 500 attempts
SALT_INCREMENT=160444  # Must match MAX_LOOP in AggregatorHookMiner.sol

echo "Starting aggregator hook mining..."
echo "Constructor args: $CONSTRUCTOR_ARGS"
echo "Protocol ID: $PROTOCOL_ID"
echo "Max attempts: $MAX_ATTEMPTS"
echo "Salt increment per attempt: $SALT_INCREMENT"
echo ""

for ((i=0; i<MAX_ATTEMPTS; i++)); do
    OFFSET=$((i * SALT_INCREMENT))
    echo "Attempt $((i + 1))/$MAX_ATTEMPTS - Salt offset: $OFFSET"
    
    # Run the forge script and capture output
    OUTPUT=$(SALT_OFFSET=$OFFSET CONSTRUCTOR_ARGS=$CONSTRUCTOR_ARGS PROTOCOL_ID=$PROTOCOL_ID forge script script/MineAggregatorHook.s.sol:MineAggregatorHookScript --via-ir 2>&1)
    
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
