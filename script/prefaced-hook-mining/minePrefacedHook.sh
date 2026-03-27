#!/usr/bin/env bash
# Mines a CREATE2 salt for arbitrary hook bytecode with a fixed leading address byte.
# Each forge invocation searches salts in [offset, offset + MAX_LOOP); on failure, reruns with offset += MAX_LOOP * workers.
#
# Usage:
#   ./script/prefaced-hook-mining/minePrefacedHook.sh [options] <prefix_byte> <creation_code> <constructor_args> [flags_hex] [deployer] [salt_start]
#
# Options (all optional):
#   --workers N | --workers=N   Parallel forge processes per round (default: CPU count via nproc/sysctl, else 4)
#   --gas-limit N | --gas-limit=N   forge --gas-limit (default: 30000000000)
#   --verbose                 Pass -vvvv to forge
#   -h, --help                Show help
#
# Positional:
#   prefix_byte       decimal (66) or hex (0x42) — required MSB of the hook address
#   creation_code     path to a file, OR inline 0x… hex (creation bytecode only, no ctor args appended)
#   constructor_args  path to a file, OR inline 0x… hex (ABI-encoded ctor args), OR "-" for empty
#   flags_hex         optional uint160 hook flags (default 0xac0 = before/after swap + before add/remove liq, matching old script)
#   deployer          optional address; use 0x0000000000000000000000000000000000000000 for canonical CREATE2 deployer proxy
#   salt_start        optional lower bound for salt search (default 0)
#
# For large bytecode, use a file path to avoid shell arg-length limits.
#
# Must match PrefacedHookMiner.MAX_LOOP in src/utils/PrefacedHookMiner.sol
MAX_LOOP=160444
# Hooks.BEFORE_SWAP | AFTER_SWAP | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY (see lib/v4-core Hooks.sol)
DEFAULT_FLAGS=0xac0
ZERO_ADDR=0x0000000000000000000000000000000000000000

FORGE_SCRIPT_REL=script/prefaced-hook-mining/MinePrefacedHook.s.sol
DEFAULT_GAS_LIMIT=30000000000

set -u

usage() {
  echo "usage: $0 [--workers N] [--gas-limit N] [--verbose] <prefix_byte> <creation_code_file|hex> <constructor_args_file|hex|-> [flags_hex] [deployer] [salt_start]" >&2
  echo "Try $0 --help for full help." >&2
  exit 1
}

show_help() {
  cat <<'EOF'
Mines a CREATE2 salt for hook bytecode with a fixed leading address byte (parallel forge workers per round).

Usage:
  minePrefacedHook.sh [options] <prefix_byte> <creation_code> <constructor_args> [flags_hex] [deployer] [salt_start]

Options:
  --workers N       Parallel forge processes per round (default: CPU count, else 4). Also --workers=N.
  --gas-limit N     forge --gas-limit (default: 30000000000). Also --gas-limit=N.
  --verbose         Run forge with -vvvv
  -h, --help        Show this help

Positional arguments match PrefacedHookMiner / forge script (see README in this directory).
EOF
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

WORKERS_OPT=""
GAS_LIMIT=$DEFAULT_GAS_LIMIT
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers=*)
      WORKERS_OPT="${1#*=}"
      shift
      ;;
    --workers)
      [[ $# -lt 2 ]] && {
        echo "error: --workers requires a value" >&2
        exit 1
      }
      WORKERS_OPT="$2"
      shift 2
      ;;
    --gas-limit=*)
      GAS_LIMIT="${1#*=}"
      shift
      ;;
    --gas-limit)
      [[ $# -lt 2 ]] && {
        echo "error: --gas-limit requires a value" >&2
        exit 1
      }
      GAS_LIMIT="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage
      ;;
    *) break ;;
  esac
done

if ! [[ "$GAS_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --gas-limit must be a positive decimal integer" >&2
  exit 1
fi

if [[ -n "$WORKERS_OPT" ]]; then
  if ! [[ "$WORKERS_OPT" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --workers must be a positive integer" >&2
    exit 1
  fi
  MINING_WORKERS=$WORKERS_OPT
else
  if command -v nproc >/dev/null 2>&1; then
    MINING_WORKERS=$(nproc)
  elif command -v sysctl >/dev/null 2>&1; then
    MINING_WORKERS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
  else
    MINING_WORKERS=4
  fi
fi

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

FLAGS=${4:-$DEFAULT_FLAGS}
DEPLOYER=${5:-$ZERO_ADDR}
BASE=${6:-0}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

SIG='run(bytes,bytes,uint256,uint8,uint160,address)'
# Plain string so worker subshells (bash 3.2) see it; empty means no extra forge args.
FORGE_VV=""
[[ "$VERBOSE" -eq 1 ]] && FORGE_VV=-vvvv

# Populated each round; declared here so INT/TERM cleanup never trips set -u.
declare -a PIDS=()

any_worker_alive() {
  local w
  for ((w = 0; w < MINING_WORKERS; w++)); do
    kill -0 "${PIDS[w]}" 2>/dev/null && return 0
  done
  return 1
}

kill_heartbeat() {
  if [[ -n "${HB_PID:-}" ]] && kill -0 "$HB_PID" 2>/dev/null; then
    kill "$HB_PID" 2>/dev/null || true
    wait "$HB_PID" 2>/dev/null || true
  fi
  HB_PID=
}

cleanup_round() {
  kill_heartbeat
  local w n=${#PIDS[@]}
  for ((w = 0; w < n; w++)); do
    if kill -0 "${PIDS[w]}" 2>/dev/null; then
      kill "${PIDS[w]}" 2>/dev/null || true
      wait "${PIDS[w]}" 2>/dev/null || true
    fi
  done
  rm -rf "${TMPROOT:-}"
}

trap 'cleanup_round; exit 130' INT
trap 'cleanup_round; exit 143' TERM

ROUND=0
while true; do
  TMPROOT=$(mktemp -d)
  PIDS=()
  declare -a OUTFILES=()
  declare -a FINISHED=()
  declare -a ECODES=()

  echo "Round $((ROUND + 1)): $MINING_WORKERS workers, base salt $BASE (windows of $MAX_LOOP each)" >&2

  for ((w = 0; w < MINING_WORKERS; w++)); do
    OFF=$((BASE + w * MAX_LOOP))
    OUTFILES[w]="$TMPROOT/w${w}.log"
    FINISHED[w]=0
    (
      forge script "${FORGE_SCRIPT_REL}:MinePrefacedHookScript" \
        --sig "$SIG" \
        --gas-limit "$GAS_LIMIT" \
        ${FORGE_VV:+"$FORGE_VV"} \
        "$BYTE_HEX" "$CTOR_HEX" "$OFF" "$PREFIX" "$FLAGS" "$DEPLOYER" >"${OUTFILES[w]}" 2>&1
      echo $? >"${OUTFILES[w]}.exit"
    ) &
    PIDS[w]=$!
  done

  START_SEC=$(date +%s)
  (
    while any_worker_alive; do
      sleep 15
      any_worker_alive || exit 0
      ELAPSED=$(( $(date +%s) - START_SEC ))
      printf "\r  ... still searching (round %d, base salt %s, %ds elapsed)   " "$((ROUND + 1))" "$BASE" "$ELAPSED" >&2
    done
  ) &
  HB_PID=$!

  SUCCESS_IDX=-1
  while true; do
    RUNNING=0
    for ((w = 0; w < MINING_WORKERS; w++)); do
      [[ "${FINISHED[w]}" -eq 1 ]] && continue
      if kill -0 "${PIDS[w]}" 2>/dev/null; then
        RUNNING=1
        continue
      fi
      wait "${PIDS[w]}" 2>/dev/null || true
      FINISHED[w]=1
      ECODES[w]=$(cat "${OUTFILES[w]}.exit" 2>/dev/null || echo 99)
      if [[ "${ECODES[w]}" -eq 0 ]]; then
        SUCCESS_IDX=$w
        break 2
      fi
    done
    [[ "$RUNNING" -eq 0 ]] && break
    sleep 0.25
  done

  kill_heartbeat
  printf "\r%-80s\r" "" >&2

  if [[ "$SUCCESS_IDX" -ge 0 ]]; then
    for ((w = 0; w < MINING_WORKERS; w++)); do
      [[ "$w" -eq "$SUCCESS_IDX" ]] && continue
      if kill -0 "${PIDS[w]}" 2>/dev/null; then
        kill "${PIDS[w]}" 2>/dev/null || true
        wait "${PIDS[w]}" 2>/dev/null || true
      fi
    done
    cat "${OUTFILES[SUCCESS_IDX]}"
    rm -rf "$TMPROOT"
    exit 0
  fi

  # All workers finished without success
  for ((w = 0; w < MINING_WORKERS; w++)); do
    if ! grep -q "could not find salt" "${OUTFILES[w]}" 2>/dev/null; then
      echo "Unexpected error (worker $w, exit ${ECODES[w]}):" >&2
      cat "${OUTFILES[w]}" >&2
      rm -rf "$TMPROOT"
      exit 1
    fi
  done

  echo "  No match in this round (${MINING_WORKERS} windows), continuing..." >&2
  BASE=$((BASE + MINING_WORKERS * MAX_LOOP))
  ROUND=$((ROUND + 1))
  rm -rf "$TMPROOT"
done
