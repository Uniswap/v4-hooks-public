#!/usr/bin/env bash
#
# mine_erc4626_salt.sh — find a CREATE2 salt for an ERC4626WrapperHook (or ERC4626RoutingHook)
# deployment whose address has BOTH the required v4 hook flags (address & 0x3fff == 0x2888) AND N
# leading zero hex digits, using the local create2crunch fork at ~/dev/create2crunch.
#
# Hooks deploy through the ERC-4626 wrapper family's AllowlistedFactory (the CREATE2 deployer), so
# FACTORY is required and every salt is mined against THAT address: a salt mined for a different
# factory (or for the 0x4e59 CREATE2-proxy path) resolves to a different address and fails the
# deploy script's checks. Deploy the factory first (script/DeployERC4626WrapperFactory.s.sol; mine
# ITS vanity salt with script/mine_factory_salt.sh using the family's ALLOWLISTED_CONTRACTS), then
# mine hook salts against it.
#
# Background (mirrors v4-periphery's HookMiner): a v4 hook address encodes its permissions in the
# low 14 bits, so the address must satisfy `address & Hooks.ALL_HOOK_MASK == flags`. HookMiner brute
# forces a CREATE2 salt for that 14-bit match in-EVM; create2crunch does the same match on GPU/CPU
# and additionally lets us demand a leading-zero vanity prefix, which is far too much work in-EVM.
#
# BaseTokenWrapperHook permissions -> flag bits (shared by ERC4626WrapperHook and ERC4626RoutingHook):
#   beforeInitialize (0x2000) | beforeAddLiquidity (0x0800) | beforeSwap (0x0080)
#     | beforeSwapReturnDelta (0x0008)  ==  0x2888        (mask Hooks.ALL_HOOK_MASK = 0x3fff)
#
# The fork's `--hook-flags` matches all 14 flag bits exactly (bits 14-15 free), so a 6-nibble prefix
# + flags is a 2^38 search. It runs the GPU by default (Metal on Apple Silicon, ~10x OpenCL there)
# and also hashes on all CPU cores unless USE_CPU=0. It renders its own live status screen (backend,
# target, difficulty as "1 in 2^N", rate, expected time per match, P(>=1 hit), recent finds), so this
# script passes it straight through to the terminal rather than scraping it. Matched salts are read
# from the efficient_addresses.txt file the miner appends to, which is independent of the display.
#
# The init-code hash (correctness anchor) is computed here from the CURRENT hook creation bytecode
# plus the ABI-encoded constructor args, exactly as the deploy site will
# (`factory.deploy(creationCode, abi.encode(poolManager, vault), salt)`). Change any constructor arg
# (or the contract) and the hash — and any previously-mined salt — is invalid. Every mined salt is
# independently re-verified here (recompute address + flag mask + prefix) before it is reported.
#
# Search / speed knobs (env):
#   MIN_LEADING_ZERO_NIBBLES 6 (default) = require a 0x000000... prefix (3 leading zero bytes).
#   MATCHES                  0 (default) = collect matches until interrupted (Ctrl-C); N>0 = stop after N.
#   GPU_DEVICE               0 (default) = first GPU; 255 = CPU-only. Metal/OpenCL index the device list.
#   USE_CPU                  1 (default) = also mine on all CPU cores; 0 = pass --no-cpu (GPU only).
#   BACKEND                  "" (default) = auto (Metal on macOS, OpenCL elsewhere); or metal | opencl.
#
# Correctness-anchor env (MUST match the deploy site exactly, or the salt won't resolve):
#   FACTORY (required) the AllowlistedFactory address (the CREATE2 deployer);
#   POOL_MANAGER, VAULT (required);
#   HOOK_CONTRACT (default src/ERC4626WrapperHook.sol:ERC4626WrapperHook) — set to
#     src/ERC4626RoutingHook.sol:ERC4626RoutingHook to mine the routing hook's salt (same flags
#     and constructor shape).
#
# Usage:
#   FACTORY=0x… POOL_MANAGER=0x… VAULT=0x… [HOOK_CONTRACT=…] [MIN_LEADING_ZERO_NIBBLES=6] \
#   [MATCHES=0] [GPU_DEVICE=0] [USE_CPU=1] [BACKEND=] [CREATE2CRUNCH_DIR=~/dev/create2crunch] [CALLER=0x0…] \
#     ./script/mine_erc4626_salt.sh                 # build (rebuilds on source change), mine, verify each match
#
#   ./script/mine_erc4626_salt.sh params            # print the CREATE2 params (init-code hash, flags, etc.)
#   ./script/mine_erc4626_salt.sh verify <salt>     # recompute a salt's address and check the conditions
set -euo pipefail

MIN_LEADING_ZERO_NIBBLES="${MIN_LEADING_ZERO_NIBBLES:-6}"
MATCHES="${MATCHES:-0}"                                          # matches to collect before stopping; 0 = until Ctrl-C
GPU_DEVICE="${GPU_DEVICE:-0}"                                    # 0 = first GPU (Metal on macOS); 255 = CPU-only
USE_CPU="${USE_CPU:-1}"                                          # 1 = also mine on all CPU cores; 0 = --no-cpu (GPU only)
BACKEND="${BACKEND:-}"                                           # ""=auto (Metal on macOS, OpenCL elsewhere); metal|opencl
CALLER="${CALLER:-0x0000000000000000000000000000000000000000}"  # the factory forwards the salt as-is
CREATE2CRUNCH_DIR="${CREATE2CRUNCH_DIR:-$HOME/dev/create2crunch}"

# The AllowlistedFactory is the CREATE2 deployer: `factory.deploy` runs the CREATE2, so the mined
# address is keccak(0xff ++ FACTORY ++ salt ++ init-code-hash). Required; no default, because a salt
# mined against the wrong deployer is silently worthless.
CREATE2_DEPLOYER="${FACTORY:-}"
# BaseTokenWrapperHook's 14 permission bits (see header). FLAG_MASK is Hooks.ALL_HOOK_MASK.
FLAG_SUFFIX="2888"
FLAG_MASK="3fff"
FLAGS_DEC=$((16#$FLAG_SUFFIX))
MASK_DEC=$((16#$FLAG_MASK))

# Which hook to mine for. ERC4626RoutingHook shares the same 14 flag bits (0x2888) and constructor
# shape (address, address), so it is mined by pointing HOOK_CONTRACT at it instead.
HOOK_CONTRACT="${HOOK_CONTRACT:-src/ERC4626WrapperHook.sol:ERC4626WrapperHook}"
HOOK_NAME="${HOOK_CONTRACT##*:}"

die() {
  echo "error: $*" >&2
  exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# ── Compute the init-code hash from the current build: keccak(creationCode ++ abi.encode(args)) ──
load_params() {
  [ -n "${INIT_CODE_HASH:-}" ] && return 0 # idempotent: only hit forge/cast once per run
  need forge
  need cast
  [ -n "$CREATE2_DEPLOYER" ] || die "FACTORY is required (the AllowlistedFactory address; deploy it with script/DeployERC4626WrapperFactory.s.sol)"
  [ -n "${POOL_MANAGER:-}" ] || die "POOL_MANAGER is required"
  [ -n "${VAULT:-}" ] || die "VAULT is required"

  echo ">> computing $HOOK_NAME init-code hash from the current build ..." >&2
  local code args
  code=$(forge inspect "$HOOK_CONTRACT" bytecode 2>/dev/null) \
    || die "forge inspect failed (does the project build?)"
  [ -n "$code" ] && [ "$code" != "0x" ] || die "empty creation bytecode from forge inspect"
  args=$(cast abi-encode "constructor(address,address)" "$POOL_MANAGER" "$VAULT") || die "cast abi-encode failed"
  INIT_CODE_HASH=$(cast keccak "$(cast concat-hex "$code" "$args")") || die "cast keccak failed"
}

print_params() {
  load_params
  cat <<EOF
FACTORY=$CREATE2_DEPLOYER
INIT_CODE_HASH=$INIT_CODE_HASH
HOOK_CONTRACT=$HOOK_CONTRACT
HOOK_FLAGS=0x$FLAG_SUFFIX
FLAG_MASK=0x$FLAG_MASK
POOL_MANAGER=$POOL_MANAGER
VAULT=$VAULT
MIN_LEADING_ZERO_NIBBLES=$MIN_LEADING_ZERO_NIBBLES
EOF
}

# ── CREATE2 address from a known salt: last 20 bytes of keccak(0xff ++ factory ++ salt ++ hash) ──
recompute_addr() {
  local salt="$1"
  need cast
  local packed h
  packed=$(cast concat-hex 0xff "$CREATE2_DEPLOYER" "$salt" "$INIT_CODE_HASH")
  h=$(cast keccak "$packed")
  echo "0x${h: -40}" | tr 'A-F' 'a-f'
}

# ── Constraint checks on a lowercase 0x-address ──
has_leading_zeros() {
  local addr="${1#0x}"
  # N '0' chars without `seq` (BSD `seq 1 0` counts DOWN); `%*s` prints N spaces -> '0's. N=0 -> "".
  local prefix
  prefix=$(printf '%*s' "$MIN_LEADING_ZERO_NIBBLES" '' | tr ' ' '0')
  [[ "$addr" == "$prefix"* ]]
}
has_flags() {
  local addr="${1#0x}"
  local val=$((16#${addr: -4}))
  (((val & MASK_DEC) == FLAGS_DEC))
}

verify_salt() {
  load_params
  local salt="$1" addr
  addr=$(recompute_addr "$salt")
  echo "salt:    $salt"
  echo "address: $addr"
  local ok=1
  if has_leading_zeros "$addr"; then echo "  leading zeros (>= $MIN_LEADING_ZERO_NIBBLES): OK"; else
    echo "  leading zeros: FAIL"
    ok=0
  fi
  if has_flags "$addr"; then echo "  hook flags (& 0x$FLAG_MASK == 0x$FLAG_SUFFIX): OK"; else
    echo "  hook flags: FAIL"
    ok=0
  fi
  [ "$ok" = 1 ] || die "salt does not satisfy the constraints"
  echo "VALID. Deploy $HOOK_NAME with this salt through the AllowlistedFactory at $CREATE2_DEPLOYER:"
  echo "  factory.deploy(type($HOOK_NAME).creationCode, abi.encode($POOL_MANAGER, $VAULT), $salt)"
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

# ── Mine with the create2crunch fork: exact flag mask + leading-zero prefix, GPU (+CPU) ──
mine() {
  load_params
  ensure_miner
  local prefix
  prefix=$(printf '%*s' "$MIN_LEADING_ZERO_NIBBLES" '' | tr ' ' '0')

  # All inputs are named flags: --factory / --caller / --init-code-hash / --gpu-device /
  # --hook-flags, plus optional --prefix, --backend and --no-cpu.
  local args=(
    --factory "$CREATE2_DEPLOYER"
    --caller "$CALLER"
    --init-code-hash "$INIT_CODE_HASH"
    --gpu-device "$GPU_DEVICE"
    --hook-flags "0x$FLAG_SUFFIX"
  )
  [ -n "$prefix" ] && args+=(--prefix "$prefix")
  [ -n "$BACKEND" ] && args+=(--backend "$BACKEND")
  # The fork mines on the CPU alongside the GPU by default; USE_CPU=0 opts out via --no-cpu. --no-cpu
  # is meaningless in CPU-only mode (GPU_DEVICE=255), so only pass it when a GPU is actually running.
  [ "$USE_CPU" = "0" ] && [ "$GPU_DEVICE" != "255" ] && args+=(--no-cpu)

  echo ">> mining $HOOK_NAME salt: address & 0x$FLAG_MASK == 0x$FLAG_SUFFIX, $MIN_LEADING_ZERO_NIBBLES leading zeros"
  echo ">>   factory=$CREATE2_DEPLOYER  caller=$CALLER"
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
