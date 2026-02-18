#!/usr/bin/env bash
# Integration tests for the Tempo Exchange aggregator hook.
# Uses `cast` to send real transactions to the Tempo chain,
# bypassing Foundry's local EVM (which can't handle Tempo precompiles).
#
# Usage:
#   ./script/test_tempo_aggregator.sh                  # run all tests
#   ./script/test_tempo_aggregator.sh test_quote        # run a single test
#
# Required env vars (or source .env):
#   PRIVATE_KEY, HOOK_ADDRESS, ROUTER_ADDRESS, TEMPO_TOKEN_0, TEMPO_TOKEN_1
# Optional:
#   RPC_URL (default: https://rpc.moderato.tempo.xyz)
#   POOL_MANAGER (default: 0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2)
#   TEMPO_EXCHANGE (default: 0xDEc0000000000000000000000000000000000000)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

# ──────── Configuration ────────

RPC_URL="${RPC_URL:-https://rpc.moderato.tempo.xyz}"
POOL_MANAGER="${POOL_MANAGER:-0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2}"
TEMPO_EXCHANGE="${TEMPO_EXCHANGE:-0xDEc0000000000000000000000000000000000000}"
PATH_USD="0x20C0000000000000000000000000000000000001"

POOL_FEE=500
TICK_SPACING=10
SWAP_AMOUNT=1000000             # 1 token (6 decimals)
FUND_AMOUNT=100000000000        # 100k tokens
LARGE_AMOUNT=5000000            # 5 tokens
MIN_PRICE_LIMIT=4295128740
MAX_PRICE_LIMIT=1461446703485210103287273052203988822378723970341

: "${PRIVATE_KEY:?Set PRIVATE_KEY}"
: "${HOOK_ADDRESS:?Set HOOK_ADDRESS}"
: "${ROUTER_ADDRESS:?Set ROUTER_ADDRESS}"
: "${TEMPO_TOKEN_0:?Set TEMPO_TOKEN_0}"
: "${TEMPO_TOKEN_1:?Set TEMPO_TOKEN_1}"

# Ensure correct token ordering
if [[ "$(echo "$TEMPO_TOKEN_0" | tr '[:upper:]' '[:lower:]')" > "$(echo "$TEMPO_TOKEN_1" | tr '[:upper:]' '[:lower:]')" ]]; then
  TMP=$TEMPO_TOKEN_0; TEMPO_TOKEN_0=$TEMPO_TOKEN_1; TEMPO_TOKEN_1=$TMP
fi

TOKEN0="$TEMPO_TOKEN_0"
TOKEN1="$TEMPO_TOKEN_1"

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
POOL_ID=$(cast keccak "$(cast abi-encode 'f(address,address,uint24,int24,address)' \
  "$TOKEN0" "$TOKEN1" $POOL_FEE $TICK_SPACING "$HOOK_ADDRESS")")

PASS_COUNT=0
FAIL_COUNT=0

echo "=== TestTempoAggregator (cast) ==="
echo "Deployer: $DEPLOYER"
echo "Hook:     $HOOK_ADDRESS"
echo "Router:   $ROUTER_ADDRESS"
echo "Token0:   $TOKEN0"
echo "Token1:   $TOKEN1"
echo "PoolId:   $POOL_ID"
echo ""

# ──────── Helpers ────────

balance_of() {
  cast call --rpc-url "$RPC_URL" "$1" 'balanceOf(address)(uint256)' "$2" | sed 's/ .*//'
}

hook_quote() {
  # quote(bool zeroToOne, int256 amountSpecified, bytes32 poolId) → uint256
  local raw
  raw=$(cast call --rpc-url "$RPC_URL" "$HOOK_ADDRESS" \
    'quote(bool,int256,bytes32)(uint256)' "$1" -- "$2" "$POOL_ID")
  echo "$raw" | sed 's/ .*//'
}

do_swap() {
  # $1=zeroForOne(bool) $2=amountSpecified(int256) $3=sqrtPriceLimitX96
  cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
    "$ROUTER_ADDRESS" \
    'swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)' \
    "($TOKEN0,$TOKEN1,$POOL_FEE,$TICK_SPACING,$HOOK_ADDRESS)" \
    "($1,$2,$3)" \
    "(false,false)" \
    "0x"
  # Brief wait for RPC state propagation across load-balanced nodes
  sleep 2
}

pass() { echo "  $1 PASS"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  $1 FAIL: $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_eq() {
  if [[ "$1" != "$2" ]]; then fail "$3" "expected $2, got $1"; return 1; fi
}

assert_gt() {
  if [[ "$1" -le "$2" ]]; then fail "$3" "$1 not > $2"; return 1; fi
}

assert_gte() {
  if [[ "$1" -lt "$2" ]]; then fail "$3" "$1 not >= $2"; return 1; fi
}

# ──────── fund ────────

fund() {
  echo "--- fund ---"

  # Check existing balances first
  local bal0; bal0=$(balance_of "$TOKEN0" "$DEPLOYER")
  local bal1; bal1=$(balance_of "$TOKEN1" "$DEPLOYER")
  local need_swap=$((LARGE_AMOUNT * 2))

  # Buy token0 if balance is low and it's not PATH_USD
  if [[ "$bal0" -lt "$need_swap" ]] && [[ "$TOKEN0" != "$PATH_USD" ]]; then
    echo "  Buying token0 via exchange..."
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
      "$PATH_USD" 'approve(address,uint256)' "$TEMPO_EXCHANGE" "$(cast max-uint)" > /dev/null
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
      "$TEMPO_EXCHANGE" 'swapExactAmountOut(address,address,uint128,uint128)(uint128)' \
      "$PATH_USD" "$TOKEN0" "$FUND_AMOUNT" 340282366920938463463374607431768211455 > /dev/null
  fi

  # Buy token1 if balance is low and it's not PATH_USD
  if [[ "$bal1" -lt "$need_swap" ]] && [[ "$TOKEN1" != "$PATH_USD" ]]; then
    echo "  Buying token1 via exchange..."
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
      "$PATH_USD" 'approve(address,uint256)' "$TEMPO_EXCHANGE" "$(cast max-uint)" > /dev/null
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
      "$TEMPO_EXCHANGE" 'swapExactAmountOut(address,address,uint128,uint128)(uint128)' \
      "$PATH_USD" "$TOKEN1" "$FUND_AMOUNT" 340282366920938463463374607431768211455 > /dev/null
  fi

  # Check allowances and approve router if needed
  # Note: allowance values can exceed bash 64-bit int range, so check string length
  local allow0; allow0=$(cast call --rpc-url "$RPC_URL" "$TOKEN0" 'allowance(address,address)(uint256)' "$DEPLOYER" "$ROUTER_ADDRESS" | sed 's/ .*//')
  local allow1; allow1=$(cast call --rpc-url "$RPC_URL" "$TOKEN1" 'allowance(address,address)(uint256)' "$DEPLOYER" "$ROUTER_ADDRESS" | sed 's/ .*//')
  if [[ "${#allow0}" -lt 20 ]] && [[ "$allow0" -lt "$need_swap" ]]; then
    echo "  Approving router for token0..."
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
      "$TOKEN0" 'approve(address,uint256)' "$ROUTER_ADDRESS" "$(cast max-uint)" > /dev/null
  fi
  if [[ "${#allow1}" -lt 20 ]] && [[ "$allow1" -lt "$need_swap" ]]; then
    echo "  Approving router for token1..."
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
      "$TOKEN1" 'approve(address,uint256)' "$ROUTER_ADDRESS" "$(cast max-uint)" > /dev/null
  fi

  bal0=$(balance_of "$TOKEN0" "$DEPLOYER")
  bal1=$(balance_of "$TOKEN1" "$DEPLOYER")
  echo "  Balance token0: $bal0"
  echo "  Balance token1: $bal1"

  if [[ "$bal0" -lt "$SWAP_AMOUNT" ]] || [[ "$bal1" -lt "$SWAP_AMOUNT" ]]; then
    fail "fund" "insufficient balance"; return 1
  fi
  pass "fund"
  echo ""
}

# ──────── Tests ────────

# NOTE: On Tempo, gas is paid in PathUSD (token0). This means token0 balance diffs
# include gas costs and are unreliable for exact assertions. Token1 balance diffs
# are unaffected by gas and can be checked exactly.

test_swapExactInput_ZeroForOne() {
  local name="test_swapExactInput_ZeroForOne"
  echo "--- $name ---"

  local expected_out; expected_out=$(hook_quote true "-$SWAP_AMOUNT")
  assert_gt "$expected_out" 0 "$name: quote > 0" || return

  local bal1_before; bal1_before=$(balance_of "$TOKEN1" "$DEPLOYER")
  do_swap true "-$SWAP_AMOUNT" "$MIN_PRICE_LIMIT" > /dev/null
  local bal1_after; bal1_after=$(balance_of "$TOKEN1" "$DEPLOYER")

  local received=$((bal1_after - bal1_before))
  echo "  received_token1: $received  quoted: $expected_out"

  assert_eq "$received" "$expected_out" "$name: received == quote" || return
  pass "$name"
  echo ""
}

test_swapExactInput_OneForZero() {
  local name="test_swapExactInput_OneForZero"
  echo "--- $name ---"

  local expected_out; expected_out=$(hook_quote false "-$SWAP_AMOUNT")
  assert_gt "$expected_out" 0 "$name: quote > 0" || return

  local bal1_before; bal1_before=$(balance_of "$TOKEN1" "$DEPLOYER")
  do_swap false "-$SWAP_AMOUNT" "$MAX_PRICE_LIMIT" > /dev/null
  local bal1_after; bal1_after=$(balance_of "$TOKEN1" "$DEPLOYER")

  local spent=$((bal1_before - bal1_after))
  echo "  spent_token1: $spent  quoted_out: $expected_out"

  # token1 spent should include the swap input + V4 pool fee
  assert_gte "$spent" "$SWAP_AMOUNT" "$name: spent >= SWAP_AMOUNT" || return
  pass "$name"
  echo ""
}

test_swapExactOutput_ZeroForOne() {
  local name="test_swapExactOutput_ZeroForOne"
  echo "--- $name ---"

  local expected_in; expected_in=$(hook_quote true "$SWAP_AMOUNT")
  assert_gt "$expected_in" 0 "$name: quote > 0" || return

  local bal1_before; bal1_before=$(balance_of "$TOKEN1" "$DEPLOYER")
  do_swap true "$SWAP_AMOUNT" "$MIN_PRICE_LIMIT" > /dev/null
  local bal1_after; bal1_after=$(balance_of "$TOKEN1" "$DEPLOYER")

  local received=$((bal1_after - bal1_before))
  echo "  received_token1: $received  quoted_in: $expected_in"

  # For exact-output ZeroForOne, we receive exact SWAP_AMOUNT of token1
  assert_eq "$received" "$SWAP_AMOUNT" "$name: received == SWAP_AMOUNT" || return
  pass "$name"
  echo ""
}

test_swapExactOutput_OneForZero() {
  local name="test_swapExactOutput_OneForZero"
  echo "--- $name ---"

  local expected_in; expected_in=$(hook_quote false "$SWAP_AMOUNT")
  assert_gt "$expected_in" 0 "$name: quote > 0" || return

  local bal1_before; bal1_before=$(balance_of "$TOKEN1" "$DEPLOYER")
  do_swap false "$SWAP_AMOUNT" "$MAX_PRICE_LIMIT" > /dev/null
  local bal1_after; bal1_after=$(balance_of "$TOKEN1" "$DEPLOYER")

  local spent=$((bal1_before - bal1_after))
  echo "  spent_token1: $spent  quoted_in: $expected_in"

  # token1 spent should be at least the quoted input
  assert_gte "$spent" "$expected_in" "$name: spent >= quote" || return
  pass "$name"
  echo ""
}

test_multipleSwaps() {
  local name="test_multipleSwaps"
  echo "--- $name ---"
  local half=$((SWAP_AMOUNT / 2))
  local quarter=$((half / 2))

  echo "  swap 1: token0->token1 exact-input $half"
  do_swap true "-$half" "$MIN_PRICE_LIMIT" > /dev/null

  echo "  swap 2: token1->token0 exact-input $half"
  do_swap false "-$half" "$MAX_PRICE_LIMIT" > /dev/null

  echo "  swap 3: token0->token1 exact-output $quarter"
  do_swap true "$quarter" "$MIN_PRICE_LIMIT" > /dev/null

  pass "$name"
  echo ""
}

test_swapLargeAmount() {
  local name="test_swapLargeAmount"
  echo "--- $name ---"

  local expected_out; expected_out=$(hook_quote true "-$LARGE_AMOUNT")
  assert_gt "$expected_out" 0 "$name: quote > 0" || return

  local bal1_before; bal1_before=$(balance_of "$TOKEN1" "$DEPLOYER")
  do_swap true "-$LARGE_AMOUNT" "$MIN_PRICE_LIMIT" > /dev/null
  local bal1_after; bal1_after=$(balance_of "$TOKEN1" "$DEPLOYER")

  local received=$((bal1_after - bal1_before))
  echo "  received_token1: $received  quoted: $expected_out"

  assert_eq "$received" "$expected_out" "$name: received == quote" || return
  pass "$name"
  echo ""
}

test_quote() {
  local name="test_quote"
  echo "--- $name ---"

  local expected_out; expected_out=$(hook_quote true "-$SWAP_AMOUNT")
  echo "  amountIn: $SWAP_AMOUNT  expectedOut: $expected_out"

  assert_gt "$expected_out" 0 "$name: quote > 0" || return

  local min_expected=$((SWAP_AMOUNT * 95 / 100))
  assert_gt "$expected_out" "$min_expected" "$name: quote within 5% for stablecoins" || return
  pass "$name"
  echo ""
}

test_pseudoTotalValueLocked() {
  local name="test_pseudoTotalValueLocked"
  echo "--- $name ---"

  local tvl; tvl=$(cast call --rpc-url "$RPC_URL" "$HOOK_ADDRESS" \
    'pseudoTotalValueLocked(bytes32)(uint256,uint256)' "$POOL_ID")
  local tvl0; tvl0=$(echo "$tvl" | head -1 | sed 's/ .*//')
  local tvl1; tvl1=$(echo "$tvl" | tail -1 | sed 's/ .*//')

  echo "  tvl0: $tvl0"
  echo "  tvl1: $tvl1"

  assert_gt "$tvl0" 0 "$name: tvl0 > 0" || return
  assert_gt "$tvl1" 0 "$name: tvl1 > 0" || return
  pass "$name"
  echo ""
}

# ──────── Main ────────

run_test() {
  # Run a test function, catching failures as FAIL instead of aborting
  local fn=$1
  local before=$FAIL_COUNT
  if ! "$fn"; then
    # Only increment if the function didn't already record a failure
    if [[ "$FAIL_COUNT" -eq "$before" ]]; then
      fail "$fn" "unexpected error"
    fi
    echo ""
  fi
}

run_all() {
  fund || { echo "fund failed, aborting"; exit 1; }
  run_test test_swapExactInput_ZeroForOne
  run_test test_swapExactInput_OneForZero
  run_test test_swapExactOutput_ZeroForOne
  run_test test_swapExactOutput_OneForZero
  run_test test_multipleSwaps
  run_test test_swapLargeAmount
  run_test test_quote
  run_test test_pseudoTotalValueLocked
}

if [[ $# -gt 0 ]]; then
  "$1"
else
  run_all
fi

echo ""
echo "=== RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
