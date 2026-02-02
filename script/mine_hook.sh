#!/bin/bash

# Mine an aggregator hook address by searching with incrementing salt offsets
# Usage: ./script/mine_hook.sh [max_attempts]

MAX_ATTEMPTS=${1:-500}  # Default to 50 attempts (~8 million salts searched)
SALT_INCREMENT=160444  # Must match MAX_LOOP in AggregatorHookMiner.sol

echo "Starting aggregator hook mining..."
echo "Max attempts: $MAX_ATTEMPTS"
echo "Salt increment per attempt: $SALT_INCREMENT"
echo ""

for ((i=0; i<MAX_ATTEMPTS; i++)); do
    OFFSET=$((i * SALT_INCREMENT))
    echo "Attempt $((i + 1))/$MAX_ATTEMPTS - Salt offset: $OFFSET"
    
    # Run the forge script and capture output
    OUTPUT=$(SALT_OFFSET=$OFFSET forge script script/MineAggregatorHook.s.sol:MineAggregatorHookScript 2>&1)
    
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
