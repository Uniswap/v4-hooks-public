#!/usr/bin/env bash
# Mines a CREATE2 salt for arbitrary hook bytecode with a fixed leading address byte.
# Each forge invocation searches salts in [offset, offset + MAX_LOOP); on failure, reruns with offset += MAX_LOOP.
#
# Usage:
#   ./script/minePrefacedHook.sh <prefix_byte> <creation_code> <constructor_args> [salt_start] [flags_hex] [deployer]
#
#   prefix_byte       decimal (66) or hex (0x42) — required MSB of the hook address
#   creation_code     path to a file, OR inline 0x… hex (creation bytecode only, no ctor args appended)
#   constructor_args  path to a file, OR inline 0x… hex (ABI-encoded ctor args), OR "-" for empty
#   salt_start        optional lower bound for salt search (default 0)
#   flags_hex         optional uint160 hook flags (default 0xac0 = before/after swap + before add/remove liq, matching old script)
#   deployer          optional address; use 0x0000000000000000000000000000000000000000 for canonical CREATE2 deployer proxy
#
# For large bytecode, use a file path to avoid shell arg-length limits.
#
# Must match PrefacedHookMiner.MAX_LOOP in src/utils/PrefacedHookMiner.sol
MAX_LOOP=160444
# Hooks.BEFORE_SWAP | AFTER_SWAP | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY (see lib/v4-core Hooks.sol)
DEFAULT_FLAGS=0xac0
ZERO_ADDR=0x0000000000000000000000000000000000000000

set -u

usage() {
  echo "usage: $0 <prefix_byte> <creation_code_file|hex> <constructor_args_file|hex|-> [salt_start] [flags_hex] [deployer]" >&2
  exit 1
}

# Normalize to raw hex (no 0x, no whitespace). Arg is a filesystem path or inline hex.
to_hex_payload() {
  local input=$1
  if [[ -f "$input" ]]; then
    local stripped
    stripped=$(tr -d '[:space:]' < "$input" | sed 's/^0x//;s/^0X//')
    if [[ "$stripped" =~ ^[0-9a-fA-F]*$ ]] && (( ${#stripped} % 2 == 0 )); then
      echo -n "$stripped"
    else
      xxd -p "$input" | tr -d '\n'
    fi
  else
    echo -n "${input#0x}" | tr -d '[:space:]'
  fi
}

[[ $# -lt 3 ]] && usage

if [[ "$1" =~ ^0[xX] ]]; then
  PREFIX=$((16#${1#0[xX]}))
else
  PREFIX=$((10#$1))
fi

if (( PREFIX < 0 || PREFIX > 255 )); then
  echo "prefix_byte must be 0-255" >&2
  exit 1
fi

BYTE_HEX="0x$(to_hex_payload "$2")"
if [[ "$3" == "-" ]]; then
  CTOR_HEX="0x"
else
  CTOR_HEX="0x$(to_hex_payload "$3")"
fi

OFFSET=${4:-0}
FLAGS=${5:-$DEFAULT_FLAGS}
DEPLOYER=${6:-$ZERO_ADDR}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SIG='run(bytes,bytes,uint256,uint8,uint160,address)'

while true; do
  if forge script script/MinePrefacedHook.s.sol:MinePrefacedHookScript \
    --sig "$SIG" \
    "$BYTE_HEX" "$CTOR_HEX" "$OFFSET" "$PREFIX" "$FLAGS" "$DEPLOYER"; then
    break
  fi
  OFFSET=$((OFFSET + MAX_LOOP))
done
