#!/usr/bin/env bash
#
# mine_factory_salt.sh — find a CREATE2 salt for the AllowlistedFactory deployment whose address
# has N leading zero hex digits, using the local create2crunch fork at ~/dev/create2crunch.
#
# The factory deploys through the canonical CREATE2 proxy (0x4e59…), which forge routes `new{salt}`
# through in DeployDualPoolFactory.s.sol, so THAT proxy is the deployer in the address derivation
# (the factory itself is the deployer only for the hooks it later deploys; see
# script/mine_dualpool_salt.sh for those). Unlike hook mining there are no v4 permission-flag bits
# to match: the factory is a plain contract, so this is a prefix-only search (6 nibbles is ~2^24,
# seconds of work, versus the hooks' ~2^38 prefix-plus-flags search).
#
# The init-code hash (correctness anchor) pins the CURRENT build of AllowlistedFactory AND the
# CURRENT builds of every allowlisted hook: the factory's constructor arg is the array
#   [keccak(DualPoolHook.creationCode),
#    keccak(DualPoolStableHook.creationCode),
#    keccak(DualPoolIncentivizedHook.creationCode)]
# in EXACTLY the order DeployDualPoolFactory.s.sol encodes it. Change any of the four contracts
# (or the array order) and the hash, and any previously-mined salt, is invalid. Keep the mined
# salt fixed across chains: same bytecode + same salt = same factory address everywhere.
#
# Search / speed knobs (env), identical to mine_dualpool_salt.sh:
#   MIN_LEADING_ZERO_NIBBLES 6 (default) = require a 0x000000... prefix (3 leading zero bytes).
#   MATCHES                  0 (default) = collect matches until interrupted (Ctrl-C); N>0 = stop after N.
#   GPU_DEVICE               0 (default) = first GPU; 255 = CPU-only. Metal/OpenCL index the device list.
#   USE_CPU                  1 (default) = also mine on all CPU cores; 0 = pass --no-cpu (GPU only).
#   BACKEND                  "" (default) = auto (Metal on macOS, OpenCL elsewhere); or metal | opencl.
#
# Usage:
#   [MIN_LEADING_ZERO_NIBBLES=6] [MATCHES=0] [GPU_DEVICE=0] [USE_CPU=1] [BACKEND=] \
#   [CREATE2CRUNCH_DIR=~/dev/create2crunch] [CALLER=0x0…] \
#     ./script/mine_factory_salt.sh                 # build (rebuilds on source change), mine, verify each match
#
#   ./script/mine_factory_salt.sh params            # print the CREATE2 params (init-code hash, prefix, etc.)
#   ./script/mine_factory_salt.sh verify <salt>     # recompute a salt's address and check the prefix
set -euo pipefail

MIN_LEADING_ZERO_NIBBLES="${MIN_LEADING_ZERO_NIBBLES:-6}"
MATCHES="${MATCHES:-0}"                                          # matches to collect before stopping; 0 = until Ctrl-C
GPU_DEVICE="${GPU_DEVICE:-0}"                                    # 0 = first GPU (Metal on macOS); 255 = CPU-only
USE_CPU="${USE_CPU:-1}"                                          # 1 = also mine on all CPU cores; 0 = --no-cpu (GPU only)
BACKEND="${BACKEND:-}"                                           # ""=auto (Metal on macOS, OpenCL elsewhere); metal|opencl
CALLER="${CALLER:-0x0000000000000000000000000000000000000000}"  # the 0x4e59 proxy forwards the salt as-is
CREATE2CRUNCH_DIR="${CREATE2CRUNCH_DIR:-$HOME/dev/create2crunch}"

# The canonical CREATE2 deployer proxy (Arachnid) that forge script routes `new{salt}` through in
# DeployDualPoolFactory.s.sol. This, not the factory, is the deployer for the factory's own address.
CREATE2_DEPLOYER="0x4e59b44847b379578588920cA78FbF26c0B4956C"

FACTORY_CONTRACT="src/AllowlistedFactory.sol:AllowlistedFactory"
# Allowlisted hook creation code, hashed into the factory's constructor arg. MUST match the
# contents AND order in DeployDualPoolFactory.s.sol, or the mined salt resolves elsewhere.
ALLOWLISTED_CONTRACTS=(
  "src/alf/DualPoolHook.sol:DualPoolHook"
  "src/alf/DualPoolStableHook.sol:DualPoolStableHook"
  "src/alf/DualPoolIncentivizedHook.sol:DualPoolIncentivizedHook"
)

die() {
  echo "error: $*" >&2
  exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# ── Compute the init-code hash from the current build: keccak(creationCode ++ abi.encode(hashes)) ──
load_params() {
  [ -n "${INIT_CODE_HASH:-}" ] && return 0 # idempotent: only hit forge/cast once per run
  need forge
  need cast

  echo ">> computing allowlisted hook creation-code hashes from the current build ..." >&2
  local hashes=() contract code
  for contract in "${ALLOWLISTED_CONTRACTS[@]}"; do
    code=$(forge inspect "$contract" bytecode 2>/dev/null) \
      || die "forge inspect $contract failed (does the project build?)"
    [ -n "$code" ] && [ "$code" != "0x" ] || die "empty creation bytecode for $contract"
    hashes+=("$(cast keccak "$code")")
    echo ">>   ${contract##*:}: ${hashes[${#hashes[@]} - 1]}" >&2
  done
  ALLOWLIST_HASHES=$(
    IFS=,
    echo "[${hashes[*]}]"
  )

  echo ">> computing AllowlistedFactory init-code hash ..." >&2
  local args
  code=$(forge inspect "$FACTORY_CONTRACT" bytecode 2>/dev/null) \
    || die "forge inspect $FACTORY_CONTRACT failed (does the project build?)"
  [ -n "$code" ] && [ "$code" != "0x" ] || die "empty creation bytecode for $FACTORY_CONTRACT"
  args=$(cast abi-encode "constructor(bytes32[])" "$ALLOWLIST_HASHES") || die "cast abi-encode failed"
  INIT_CODE_HASH=$(cast keccak "$(cast concat-hex "$code" "$args")") || die "cast keccak failed"
}

print_params() {
  load_params
  cat <<EOF
CREATE2_DEPLOYER=$CREATE2_DEPLOYER
INIT_CODE_HASH=$INIT_CODE_HASH
ALLOWLIST_HASHES=$ALLOWLIST_HASHES
MIN_LEADING_ZERO_NIBBLES=$MIN_LEADING_ZERO_NIBBLES
EOF
}

# ── CREATE2 address from a known salt: last 20 bytes of keccak(0xff ++ deployer ++ salt ++ hash) ──
recompute_addr() {
  local salt="$1"
  need cast
  local packed h
  packed=$(cast concat-hex 0xff "$CREATE2_DEPLOYER" "$salt" "$INIT_CODE_HASH")
  h=$(cast keccak "$packed")
  echo "0x${h: -40}" | tr 'A-F' 'a-f'
}

# ── Constraint check on a lowercase 0x-address ──
has_leading_zeros() {
  local addr="${1#0x}"
  # N '0' chars without `seq` (BSD `seq 1 0` counts DOWN); `%*s` prints N spaces -> '0's. N=0 -> "".
  local prefix
  prefix=$(printf '%*s' "$MIN_LEADING_ZERO_NIBBLES" '' | tr ' ' '0')
  [[ "$addr" == "$prefix"* ]]
}

verify_salt() {
  load_params
  local salt="$1" addr
  addr=$(recompute_addr "$salt")
  echo "salt:    $salt"
  echo "address: $addr"
  if has_leading_zeros "$addr"; then echo "  leading zeros (>= $MIN_LEADING_ZERO_NIBBLES): OK"; else
    echo "  leading zeros: FAIL"
    die "salt does not satisfy the constraints"
  fi
  echo "VALID. Deploy AllowlistedFactory with this salt via the 0x4e59 CREATE2 proxy:"
  echo "  FACTORY_SALT=$salt MIN_LEADING_ZERO_NIBBLES=$MIN_LEADING_ZERO_NIBBLES forge script script/DeployDualPoolFactory.s.sol"
}

# ── Miner process/tempdir bookkeeping ──
_mine_pids=()
_mine_tmp=""
# Stop the miner but leave the temp dir intact so its collected matches can still be read.
_mine_stop() {
  local p
  # SIGKILL: the miner is a tight compute loop and may not stop on SIGTERM; without this a killed
  # run would leave a CPU/GPU-pinned worker behind.
  for p in ${_mine_pids[@]:-}; do kill -9 "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  _mine_pids=()
}
_mine_cleanup() {
  _mine_stop
  [ -n "$_mine_tmp" ] && rm -rf "$_mine_tmp"
  _mine_tmp=""
}

# ── Build the create2crunch fork (rebuilds incrementally so new backends are picked up) ──
ensure_miner() {
  if [ -n "${CREATE2CRUNCH_BIN:-}" ]; then
    [ -x "$CREATE2CRUNCH_BIN" ] || die "CREATE2CRUNCH_BIN is not executable: $CREATE2CRUNCH_BIN"
    return 0
  fi
  [ -d "$CREATE2CRUNCH_DIR" ] || die "create2crunch fork not found at $CREATE2CRUNCH_DIR (set CREATE2CRUNCH_DIR or CREATE2CRUNCH_BIN)"
  need cargo
  # `cargo build` is incremental: a no-op when up to date, so we always run the latest fork.
  echo ">> building create2crunch (release) in $CREATE2CRUNCH_DIR ..." >&2
  (cd "$CREATE2CRUNCH_DIR" && cargo build --release) >&2 || die "cargo build failed"
  CREATE2CRUNCH_BIN="$CREATE2CRUNCH_DIR/target/release/create2crunch"
  [ -x "$CREATE2CRUNCH_BIN" ] || die "miner binary not found at $CREATE2CRUNCH_BIN"
}

# ── Mine with the create2crunch fork: leading-zero prefix only (no hook flags), GPU (+CPU) ──
mine() {
  # A zero-nibble target means any salt works (including bytes32(0)); nothing to mine.
  [ "$MIN_LEADING_ZERO_NIBBLES" -gt 0 ] \
    || die "MIN_LEADING_ZERO_NIBBLES=0: nothing to mine; use FACTORY_SALT=0x0…0 directly"
  load_params
  ensure_miner
  local prefix
  prefix=$(printf '%*s' "$MIN_LEADING_ZERO_NIBBLES" '' | tr ' ' '0')

  local args=(
    --factory "$CREATE2_DEPLOYER"
    --caller "$CALLER"
    --init-code-hash "$INIT_CODE_HASH"
    --gpu-device "$GPU_DEVICE"
    --prefix "$prefix"
  )
  [ -n "$BACKEND" ] && args+=(--backend "$BACKEND")
  # The fork mines on the CPU alongside the GPU by default; USE_CPU=0 opts out via --no-cpu. --no-cpu
  # is meaningless in CPU-only mode (GPU_DEVICE=255), so only pass it when a GPU is actually running.
  [ "$USE_CPU" = "0" ] && [ "$GPU_DEVICE" != "255" ] && args+=(--no-cpu)

  echo ">> mining AllowlistedFactory salt: $MIN_LEADING_ZERO_NIBBLES leading zeros (no flag bits)"
  echo ">>   deployer=$CREATE2_DEPLOYER  caller=$CALLER"
  echo ">>   init-code-hash=$INIT_CODE_HASH"

  # Pass the miner's live status screen straight through to this terminal (it renders backend, target,
  # difficulty, rate, expected time per match, P(>=1 hit) and recent finds itself) — no capture, no
  # scraping. Run in a fresh temp dir so its efficient_addresses.txt holds only this run's matches, and
  # read the matched salts from that file, which is written independently of the display.
  _mine_tmp=$(mktemp -d)
  local out="$_mine_tmp/efficient_addresses.txt"
  # Ctrl-C ends the search but we still want to verify whatever was collected, so INT only flips a flag
  # and lets the loop finish gracefully; the miner shares this process group and takes the same SIGINT.
  # TERM and normal EXIT still hard-clean (kill + remove temp dir).
  local interrupted=0
  trap 'interrupted=1' INT
  trap _mine_cleanup EXIT TERM
  (cd "$_mine_tmp" && exec "$CREATE2CRUNCH_BIN" "${args[@]}") &
  _mine_pids=("$!")

  # The miner appends each match to efficient_addresses.txt as `0x<64-hex salt> => <addr> => …` and
  # runs until killed. Poll (silently, so as not to disturb the live screen) until we have MATCHES of
  # them (MATCHES=0 => run until interrupted), the user Ctrl-C's, or the miner exits on its own.
  local count=0
  while :; do
    count=$(grep -ciE '0x[0-9a-f]{64}' "$out" 2>/dev/null || true)
    [ -n "$count" ] || count=0
    [ "$MATCHES" -gt 0 ] && [ "$count" -ge "$MATCHES" ] && break
    [ "$interrupted" = 1 ] && break
    # If the miner exited on its own (e.g. an argument error), its message is already on screen above.
    kill -0 "${_mine_pids[0]}" 2>/dev/null || break
    sleep 3 || true # a trapped SIGINT interrupts sleep; don't let that trip `set -e`
  done

  # Stop the miner but keep the temp dir so we can read the matches it collected, then remove it.
  _mine_stop
  local salts=() s
  if [ -s "$out" ]; then
    # De-duplicate in discovery order and cap to MATCHES (an easy pattern can pile up more than asked).
    while IFS= read -r s; do
      salts+=("$s")
      [ "$MATCHES" -gt 0 ] && [ "${#salts[@]}" -ge "$MATCHES" ] && break
    done < <(grep -oiE '0x[0-9a-f]{64}' "$out" | awk '!seen[$0]++')
  fi
  rm -rf "$_mine_tmp"
  _mine_tmp=""
  trap - EXIT INT TERM

  [ "${#salts[@]}" -gt 0 ] || die "create2crunch produced no salt (see its output above)"

  echo ""
  echo ">> collected ${#salts[@]} match(es); independent verification (recompute + conditions):"
  local i=1
  for s in "${salts[@]}"; do
    echo ""
    echo "── match $i of ${#salts[@]} ──"
    verify_salt "$s"
    i=$((i + 1))
  done
}

case "${1:-mine}" in
params) print_params ;;
verify) verify_salt "${2:?usage: verify <salt>}" ;;
mine) mine ;;
*) die "unknown subcommand: $1 (params|verify|mine)" ;;
esac
