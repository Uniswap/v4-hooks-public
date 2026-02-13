#!/usr/bin/env bash
# Fetches all TIP-20 tokens from the Tempo factory and outputs ABI-encoded address[].
# Used by InitializeTempoPools.s.sol via FFI.
#
# Usage: ./script/util/fetch_tempo_tokens.sh <RPC_URL>

set -euo pipefail

RPC_URL="${1:?Usage: fetch_tempo_tokens.sh <RPC_URL>}"

# TIP-20 Factory (precompile)
TIP20_FACTORY="0x20Fc000000000000000000000000000000000000"

# PathUSD genesis token — not emitted via factory events
PATH_USD="0x20C0000000000000000000000000000000000000"

# TokenCreated(address indexed token) event signature
EVENT_SIG="0x$(cast keccak 'TokenCreated(address)')"

# Fetch factory logs
LOGS=$(cast logs \
  --from-block 0 \
  --to-block latest \
  --address "$TIP20_FACTORY" \
  "$EVENT_SIG" \
  --rpc-url "$RPC_URL" \
  --json 2>/dev/null || echo "[]")

# Extract token addresses from topic[1] (indexed address, left-padded to 32 bytes)
TOKENS=("$PATH_USD")
while IFS= read -r addr; do
  [ -z "$addr" ] && continue
  # topic is 0x000...addr (66 chars), extract last 40 hex chars
  clean="0x${addr: -40}"
  TOKENS+=("$clean")
done < <(echo "$LOGS" | jq -r '.[].topics[1] // empty')

# Build ABI-encoded address[] using cast
# Format: (address[])
ADDR_LIST=$(printf "%s," "${TOKENS[@]}")
ADDR_LIST="[${ADDR_LIST%,}]"

cast abi-encode "f(address[])" "$ADDR_LIST"
