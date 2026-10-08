#!/usr/bin/env bash
# Anvil fork rehearsal of the live Robinhood Chain (4663) index vault, with no real funds and no real keys.
#
# Forks 4663, answers the ArbSys precompile, and rehearses on the LIVE StablePairHook, pools and IndexLpVault of
# tooling/deployments/4663.json: funds a test user from the PoolManager by impersonation, deposits 20 QQQ of value into
# the ten positions, reads the vault's views, swaps 0.5 NVDA through the NVDA/QQQ pool, trips the deviation guard by
# pushing that pool 2% off its reference, shocks NVDA's reference +2% with batchUpdateFeeConfig as the impersonated
# deployer (getFee printed across mined blocks), restores it, and redeems everything. The only contract it deploys is
# v4-core's PoolSwapTest router, on the fork. Every transaction is an eth_sendTransaction to the local anvil from an
# impersonated account: nothing is signed and nothing reaches 4663.
#
#   bash tooling/fork/rehearsal.sh
#
# Env: RPC_4663 (default: the public Robinhood Chain RPC), PORT (default 8546), FORK_BLOCK (default: latest).
# Needs Foundry (anvil, cast, forge) and python3; exits non-zero on the first failed check.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

RPC_4663=${RPC_4663:-https://rpc.mainnet.chain.robinhood.com}
PORT=${PORT:-8546}
LOCAL="http://127.0.0.1:$PORT"
DEPLOYMENTS="$ROOT/tooling/deployments/4663.json"
TMP=${TMPDIR:-/tmp}
TMP=${TMP%/}

DEPLOYER=0x45c35C4d1bc85A1339573c3Bd5Cf0C890bbbb6c3 # hook admin, pool initializer and config manager; vault owner
ALICE=0x00000000000000000000000000000000000A11CE    # fresh test user
ARB_SYS=0x0000000000000000000000000000000000000064
CONFIG_MANAGER_ROLE=0xbbfb55d933c2bfa638763473275b1d84c4418e58d26cf9d2cd5758237756d9f0
DYNAMIC_FEE=8388608 # LPFeeLibrary.DYNAMIC_FEE_FLAG: the fee field of every pool key
MIN_SQRT_PRICE_PLUS_ONE=4295128740
MAX_SQRT_PRICE_MINUS_ONE=1461446703485210103287273052203988822378723970341
MAX_UINT=0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
TEN_ETH=0x8AC7230489E80000
DEPOSIT_VALUE=20000000000000000000 # 20 QQQ of value
SWAP_IN=500000000000000000         # 0.5 NVDA
SWAP_FUNDING=30000000000000000000  # NVDA and QQQ funded on top of the deposit's for the swaps: the 2% push and its
#                                    restore cost ~0.55 NVDA and ~0.17 QQQ per 20 QQQ in the vault (covers ~1000 QQQ)
SHOCK_BLOCKS="1 5 20 100 1000"     # getFee is read this many blocks after the reference shock (and right at it)
ERRORS="PriceDeviation(uint256) SlippageExceeded() ZeroShares() LengthMismatch() DepositsArePaused() ZeroNav()
PoolNotInitialized(bytes32) AccessControlUnauthorizedAccount(address,bytes32) Error(string)"

# ------------------------------------------------------------------------------------------------------------ helpers
# NB: bash does not apply `set -e` inside $(...), so every function used there checks its own steps (`|| return 1`)

banner() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() {
  printf '\nFAIL: %s\n' "$*" >&2
  exit 1
}
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

PY_PRELUDE='import json, math, sys
a = sys.argv[1:]
Q96 = 2**96
def tok(x, d=18): return "{:,.6f}".format(int(x) / 10**d)
def ints(s): return [int(x) for x in s.split(",")] if s else []
def pct(fee_e6): return "{:.4f}%".format(int(fee_e6) / 1e4)
def vs_ref(sp, ref): return "{:+.3f}%".format(((int(sp) / int(ref)) ** 2 - 1) * 100)
def in_band(sp, ref, maxdev):  # IndexLpVault (IndexVaultMath.withinBand)
    lo, hi = min(int(sp), int(ref)), max(int(sp), int(ref))
    r = lo * 2**48 // hi
    return r * r * 10000 >= Q96 * (10000 - int(maxdev))
'
py() {
  local code=$1
  shift
  python3 -I -c "$PY_PRELUDE$code" "$@"
}

cj() { cast call --rpc-url "$LOCAL" --json "$@"; } # decoded outputs as JSON
c1() {                                              # a single decoded output
  local out
  out=$(cast call --rpc-url "$LOCAL" "$@") || return 1
  printf '%s\n' "${out%% *}"
}
rpc() { cast rpc --rpc-url "$LOCAL" "$@" >/dev/null; }
mine() { rpc anvil_mine "$(printf '0x%x' "$1")"; }
block() { cast block-number --rpc-url "$LOCAL"; }
rint() { py 'print(int(json.loads(a[0])[a[1]], 16))' "$1" "$2"; } # an integer field of a receipt

# decode_revert TEXT: the revert data in a cast error message, decoded when it is one of the vault's or hook's errors
decode_revert() {
  local data sig
  data=$(printf '%s' "$1" | grep -o 'data: "0x[0-9a-fA-F]*"' | head -1 | grep -o '0x[0-9a-fA-F]*' || true)
  if [[ -z "$data" ]]; then
    printf '%s' "$1" | tail -3
    return 0
  fi
  for sig in $ERRORS; do
    if [[ "$(lc "$data")" == "$(cast sig "$sig")"* ]]; then
      printf '%s(%s)' "${sig%%(*}" "$(cast decode-error --sig "$sig" "$data" | paste -sd, -)"
      return 0
    fi
  done
  printf 'unknown revert %s' "$data"
}

# send FROM TO|--create SIG|CODE [ARGS...]: eth_sendTransaction from an impersonated account; prints the receipt JSON,
# dies (with the decoded revert) unless the transaction succeeded
send() {
  local from=$1 what out errf err
  shift
  what="$1 ${2:-}"
  if [[ "$1" == --create ]]; then what="a contract creation"; fi
  errf=$(mktemp "$TMP/rehearsal-send.XXXXXX")
  if ! out=$(cast send --rpc-url "$LOCAL" --unlocked --from "$from" --json "$@" 2>"$errf"); then
    err=$(cat "$errf")
    rm -f "$errf"
    die "transaction from $from failed ($what): $(decode_revert "$err")"
  fi
  rm -f "$errf"
  [[ "$(py 'print(json.loads(a[0])["status"])' "$out")" == 0x1 ]] || die "transaction from $from reverted ($what)"
  printf '%s\n' "$out"
}

# expect_revert LABEL WANT CMD...: CMD must fail with the decoded revert WANT, e.g. "PriceDeviation(0)"
expect_revert() {
  local label=$1 want=$2 out got
  shift 2
  if out=$("$@" 2>&1); then die "$label: expected the revert $want, but it succeeded"; fi
  got=$(decode_revert "$out")
  [[ "$got" == "$want" ]] || die "$label: expected the revert $want, got $got"
  info "$label reverts $got, as expected"
}

key() { printf '(%s,%s,%s,%s,%s)' "${C0[$1]}" "${C1[$1]}" "$DYNAMIC_FEE" "${TS[$1]}" "$HOOK"; }

# slot0 I: "sqrtPriceX96 tick" of pool I
slot0() {
  local o
  o=$(cj "$SV" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "${PID[$1]}") || return 1
  py 'v = json.loads(a[0]); print(int(v[0]), int(v[1]))' "$o"
}

# fee_config I: "k optimalFeeE6 targetMultiplier referenceSqrtPriceX96" of pool I on the hook
fee_config() {
  local o
  o=$(cj "$HOOK" "feeConfig(bytes32)(uint24,uint24,uint8,uint160)" "${PID[$1]}") || return 1
  py 'print(" ".join(str(int(x)) for x in json.loads(a[0])))' "$o"
}

# get_fee I: the hook's "zeroForOne oneForZero" LP fees (E6) for a swap on pool I in the latest block's context
get_fee() {
  local o
  o=$(cj "$HOOK" "getFee((address,address,uint24,int24,address))(uint24,uint24)" "$(key "$1")") || return 1
  py 'v = json.loads(a[0]); print(int(v[0]), int(v[1]))' "$o"
}

# set_reference I SQRT_PRICE: batchUpdateFeeConfig from the impersonated deployer, keeping the other three fields
set_reference() {
  local fc k opt mult ref
  fc=$(fee_config "$1") || return 1
  read -r k opt mult ref <<<"$fc"
  send "$DEPLOYER" "$HOOK" "batchUpdateFeeConfig(bytes32[],(uint24,uint24,uint8,uint160)[])" \
    "[${PID[$1]}]" "[($k,$opt,$mult,$2)]"
}

# balances ADDR: comma-separated balances of the stocks (constituent order) then QQQ
balances() {
  local t b out=""
  for ((t = 0; t <= N; t++)); do
    b=$(c1 "${TOKENS[t]}" "balanceOf(address)(uint256)" "$1") || return 1
    out+="$b,"
  done
  printf '%s\n' "${out%,}"
}

# swap I ZERO_FOR_ONE AMOUNT_IN SQRT_PRICE_LIMIT: ALICE's exact-input swap through pool I via the router; the receipt
swap() {
  send "$ALICE" "$ROUTER" "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)" \
    "$(key "$1")" "($2,-$3,$4)" "(false,false)" 0x
}

# swap_to I TARGET: moves pool I's sqrt price exactly to TARGET with a price-limited exact-input swap that offers ALICE's
# whole balance of the input token (the pool takes only what the move costs, nothing while it has no liquidity)
swap_to() {
  local i=$1 target=$2 s sp tick down tin amt
  s=$(slot0 "$i") || return 1
  read -r sp tick <<<"$s"
  down=$(py 'print("true" if int(a[0]) > int(a[1]) else "false")' "$sp" "$target") || return 1
  if [[ "$down" == true ]]; then tin=${C0[i]}; else tin=${C1[i]}; fi
  amt=$(c1 "$tin" "balanceOf(address)(uint256)" "$ALICE") || return 1
  if [[ "$amt" == 0 ]]; then amt=1; fi
  swap "$i" "$down" "$amt" "$target" >/dev/null || return 1
  s=$(slot0 "$i") || return 1
  read -r sp tick <<<"$s"
  [[ "$sp" == "$target" ]] || die "${SYM[i]}: the price-limited swap stopped at sqrtPriceX96 $sp, not $target"
}

# ------------------------------------------------------------------------------------------------------------ anvil
ANVIL_PID=""
ANVIL_LOG=""
cleanup() {
  local rc=$?
  if [[ -n "$ANVIL_PID" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
  if [[ -n "$ANVIL_LOG" ]]; then
    if [[ $rc -eq 0 ]]; then rm -f "$ANVIL_LOG"; else printf 'anvil log kept at %s\n' "$ANVIL_LOG" >&2; fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------------------------------------------------ 0. setup
banner "Preflight: tools, deployments file, bytecode (forge compiles on a cold cache)"
for t in anvil cast forge python3; do command -v "$t" >/dev/null || die "$t is not on PATH"; done
[[ -f "$DEPLOYMENTS" ]] || die "missing $DEPLOYMENTS"
DEP=$(py 'd = json.load(open(a[0]))
print(d["chainId"], d["hook"], d["vault"], d["poolManager"], d["positionManager"], d["stateView"], d["indexToken"])' \
  "$DEPLOYMENTS")
read -r CHAIN HOOK VAULT PM POSM SV QQQ <<<"$DEP"
[[ "$CHAIN" == 4663 ]] || die "the deployments file is for chain $CHAIN, not 4663"
CONS=$(py 'd = json.load(open(a[0]))
for c in d["constituents"]:
    print(c["symbol"], c["stock"], c["currency0"], c["currency1"], c["poolId"], c["tickSpacing"], c["targetBps"])' \
  "$DEPLOYMENTS")
[[ -n "$CONS" ]] || die "no constituents in $DEPLOYMENTS"
N=0
while read -r sym stock c0 c1 pid ts tb; do
  SYM[N]=$sym STOCK[N]=$stock C0[N]=$c0 C1[N]=$c1 PID[N]=$pid TS[N]=$ts TB[N]=$tb
  N=$((N + 1))
done <<<"$CONS"
TOKENS=("${STOCK[@]}" "$QQQ")
TOKEN_SYMS=("${SYM[@]}" QQQ)
NV=-1
for ((i = 0; i < N; i++)); do if [[ "${SYM[i]}" == NVDA ]]; then NV=$i; fi; done
[[ $NV -ge 0 ]] || die "no NVDA constituent"
if [[ "$(lc "${STOCK[NV]}")" == "$(lc "${C0[NV]}")" ]]; then NV_IS_0=true; else NV_IS_0=false; fi
ARBSYS_RUNTIME=$(forge inspect ArbSysMock deployedBytecode | tail -n 1)
ROUTER_INITCODE=$(forge inspect PoolSwapTest bytecode | tail -n 1)
[[ "$ARBSYS_RUNTIME" == 0x60* && "$ROUTER_INITCODE" == 0x60* ]] || die "forge inspect returned no bytecode"
info "hook $HOOK, vault $VAULT, $N constituents, NVDA is constituent $NV"

banner "Fork 4663 with anvil on $LOCAL (--auto-impersonate, a block per transaction, anvil_mine for the rest)"
if cast chain-id --rpc-url "$LOCAL" >/dev/null 2>&1; then die "$LOCAL already answers: stop that node or set PORT"; fi
ANVIL_LOG=$(mktemp "$TMP/index-vault-rehearsal-anvil.XXXXXX")
anvil --fork-url "$RPC_4663" --port "$PORT" --auto-impersonate ${FORK_BLOCK:+--fork-block-number "$FORK_BLOCK"} \
  >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 120); do
  if cast chain-id --rpc-url "$LOCAL" >/dev/null 2>&1; then break; fi
  kill -0 "$ANVIL_PID" 2>/dev/null || {
    tail -20 "$ANVIL_LOG" >&2
    die "anvil exited"
  }
  sleep 0.5
done
[[ "$(cast client --rpc-url "$LOCAL" 2>/dev/null)" == anvil* ]] || die "$LOCAL is not an anvil node"
[[ "$(cast chain-id --rpc-url "$LOCAL")" == 4663 ]] || die "$LOCAL is not a fork of 4663"
FORK_BN=$(block)
info "anvil pid $ANVIL_PID, fork block $FORK_BN"

banner "Answer ArbSys (0x64) with ArbSysMock: the live hook's BlockNumberish reads arbBlockNumber(), Nitro's placeholder reverts"
rpc anvil_setCode "$ARB_SYS" "$ARBSYS_RUNTIME"
ARB_BN=$(c1 "$ARB_SYS" "arbBlockNumber()(uint256)")
[[ "$ARB_BN" == "$(block)" ]] || die "arbBlockNumber() = $ARB_BN, not the block number"
info "arbBlockNumber() = $ARB_BN = block.number"
for who in "$PM" "$ALICE" "$DEPLOYER"; do rpc anvil_setBalance "$who" "$TEN_ETH"; done

banner "Live deployment: code at the hook and the vault, ten constituents matching the deployments file"
[[ "$(cast code --rpc-url "$LOCAL" "$HOOK")" != 0x ]] || die "no code at the hook $HOOK"
[[ "$(cast code --rpc-url "$LOCAL" "$VAULT")" != 0x ]] || die "no code at the vault $VAULT"
COUNT=$(c1 "$VAULT" "constituentCount()(uint256)")
[[ "$COUNT" == 10 && "$COUNT" == "$N" ]] || die "constituentCount() = $COUNT; the deployments file lists $N"
for ((i = 0; i < N; i++)); do
  CV=$(cj "$VAULT" "constituent(uint256)((address,bytes32,uint256,uint16,int24,int24))" "$i")
  py 'v = json.loads(a[0])[0]
sys.exit(0 if v[0].lower() == a[1].lower() and v[1].lower() == a[2].lower() and int(v[3]) == int(a[3]) else 1)' \
    "$CV" "${STOCK[i]}" "${PID[i]}" "${TB[i]}" || die "constituent $i (${SYM[i]}) differs from the deployments file"
  ENC=$(cast abi-encode "k(address,address,uint24,int24,address)" "${C0[i]}" "${C1[i]}" "$DYNAMIC_FEE" "${TS[i]}" "$HOOK")
  [[ "$(lc "$(cast keccak "$ENC")")" == "$(lc "${PID[i]}")" ]] || die "${SYM[i]}: its pool key does not hash to its poolId"
done
[[ "$(lc "$(c1 "$VAULT" "owner()(address)")")" == "$(lc "$DEPLOYER")" ]] || die "the vault owner is not the deployer"
[[ "$(lc "$(c1 "$VAULT" "indexToken()(address)")")" == "$(lc "$QQQ")" ]] || die "the vault's index token is not QQQ"
[[ "$(c1 "$HOOK" "hasRole(bytes32,address)(bool)" "$CONFIG_MANAGER_ROLE" "$DEPLOYER")" == true ]] ||
  die "the deployer does not hold CONFIG_MANAGER_ROLE"
[[ "$(c1 "$VAULT" "depositsPaused()(bool)")" == false ]] || die "deposits are paused on the vault"
MAXDEV=$(c1 "$VAULT" "maxDeviationBps()(uint16)")
SUPPLY0=$(c1 "$VAULT" "totalSupply()(uint256)")
NAV0=$(c1 "$VAULT" "nav()(uint256)")
info "constituentCount() = $COUNT; owner = deployer (holds CONFIG_MANAGER_ROLE); maxDeviationBps = $MAXDEV"
info "totalSupply = $SUPPLY0, nav = $NAV0 (first deposit: $([[ "$SUPPLY0" == 0 ]] && echo yes || echo no))"

banner "Deploy v4-core's PoolSwapTest on the fork as ALICE's swap router (the rehearsal's only new contract)"
CTOR=$(cast abi-encode "constructor(address)" "$PM")
R=$(send "$ALICE" --create "${ROUTER_INITCODE}${CTOR#0x}")
ROUTER=$(py 'print(json.loads(a[0])["contractAddress"])' "$R")
info "PoolSwapTest at $ROUTER"

banner "Pools vs their hook references (a deposit reverts PriceDeviation(i) past maxDeviationBps = $MAXDEV)"
ROWS=""
for ((i = 0; i < N; i++)); do
  S=$(slot0 "$i")
  FC=$(fee_config "$i")
  LIQ=$(c1 "$SV" "getLiquidity(bytes32)(uint128)" "${PID[i]}")
  read -r SP TICK <<<"$S"
  read -r K OPT MULT REF <<<"$FC"
  if [[ "$(lc "${STOCK[i]}")" == "$(lc "${C0[i]}")" ]]; then S0=1; else S0=0; fi
  ROWS+="${SYM[i]} $SP $TICK $OPT $REF $LIQ $S0"$'\n'
done
py 'print("    %-6s %7s %16s %8s %22s  %s" % ("pool", "tick", "stock vs ref", "optimal", "active liquidity", "deposit band"))
for line in a[1].strip().splitlines():
    sym, sp, tick, opt, ref, liq, s0 = line.split()
    dev = vs_ref(sp, ref) if s0 == "1" else vs_ref(ref, sp)
    print("    %-6s %7s %16s %8s %22s  %s" % (sym, tick, dev, pct(opt), liq, "in" if in_band(sp, ref, a[0]) else "OUT"))' \
  "$MAXDEV" "$ROWS"
OUT=$(py 'print(" ".join(str(k) for k, l in enumerate(a[1].strip().splitlines()) if not in_band(l.split()[1], l.split()[4], a[0])))' \
  "$MAXDEV" "$ROWS")
for i in $OUT; do
  # Without liquidity a swap moves the price for free, and a reference the keeper moved past the band blocks deposits
  LIQ=$(c1 "$SV" "getLiquidity(bytes32)(uint128)" "${PID[i]}")
  [[ "$LIQ" == 0 ]] ||
    die "${SYM[i]} is out of band with liquidity: a live deposit reverts PriceDeviation($i) until it is arbitraged back"
  FC=$(fee_config "$i")
  read -r K OPT MULT REF <<<"$FC"
  swap_to "$i" "$REF"
  info "ALIGNED ON THE FORK ONLY: ${SYM[i]}'s empty pool swapped to its reference for free. On 4663 the first deposit"
  info "reverts PriceDeviation($i) until someone does the same."
done

# ------------------------------------------------------------------------------------------------------------ 1. deposit
banner "Fund ALICE ($ALICE) from the PoolManager by impersonation: 1.5x previewDeposit(20 QQQ), plus 30 NVDA / QQQ to swap"
PV=$(cj "$VAULT" "previewDeposit(uint256)(uint256[],uint256[],uint256)" "$DEPOSIT_VALUE")
PVF=$(py 'v = json.loads(a[0]); print(",".join(str(int(x)) for x in v[0]), ",".join(str(int(x)) for x in v[1]), int(v[2]))' "$PV")
read -r STOCK_AMTS INDEX_AMTS PREVIEW_SHARES <<<"$PVF"
FUND=$(py 'stock, index, nv, extra = ints(a[0]), ints(a[1]), int(a[2]), int(a[3])
print(" ".join(str(s * 3 // 2 + (extra if k == nv else 0)) for k, s in enumerate(stock)), sum(index) * 3 // 2 + extra)' \
  "$STOCK_AMTS" "$INDEX_AMTS" "$NV" "$SWAP_FUNDING")
read -r -a FUND_AMT <<<"$FUND"
ROWS=""
for ((t = 0; t <= N; t++)); do
  PMBAL=$(c1 "${TOKENS[t]}" "balanceOf(address)(uint256)" "$PM")
  py 'sys.exit(0 if int(a[0]) >= int(a[1]) else 1)' "$PMBAL" "${FUND_AMT[t]}" ||
    die "the PoolManager holds $PMBAL ${TOKEN_SYMS[t]}, less than the ${FUND_AMT[t]} to fund"
  send "$PM" "${TOKENS[t]}" "transfer(address,uint256)" "$ALICE" "${FUND_AMT[t]}" >/dev/null
  ROWS+="${TOKEN_SYMS[t]} $PMBAL ${FUND_AMT[t]}"$'\n'
done
py 'stock, index = ints(a[0]), ints(a[1]); preview = stock + [sum(index)]
print("    %-6s %24s %16s %16s" % ("token", "PoolManager balance", "previewDeposit", "funded ALICE"))
for k, line in enumerate(a[2].strip().splitlines()):
    sym, pm, funded = line.split()
    print("    %-6s %24s %16s %16s" % (sym, tok(pm), tok(preview[k]), tok(funded)))
print("    previewDeposit(20 QQQ) shares: " + tok(a[3]))' "$STOCK_AMTS" "$INDEX_AMTS" "$ROWS" "$PREVIEW_SHARES"

banner "Deposit: ALICE approves the 11 tokens to the vault and deposits the previewed amounts (minShares = 99.5%)"
for ((t = 0; t <= N; t++)); do send "$ALICE" "${TOKENS[t]}" "approve(address,uint256)" "$VAULT" "$MAX_UINT" >/dev/null; done
MIN_SHARES=$(py 'print(int(a[0]) * 995 // 1000)' "$PREVIEW_SHARES")
BAL_BEFORE=$(balances "$ALICE")
R=$(send "$ALICE" "$VAULT" "deposit(uint256[],uint256[],uint256,address)" "[$STOCK_AMTS]" "[$INDEX_AMTS]" "$MIN_SHARES" "$ALICE")
DEPOSIT_GAS=$(rint "$R" gasUsed)
BAL_AFTER=$(balances "$ALICE")
SHARES=$(c1 "$VAULT" "balanceOf(address)(uint256)" "$ALICE")
py 'sys.exit(0 if int(a[0]) >= int(a[1]) else 1)' "$SHARES" "$MIN_SHARES" || die "ALICE holds $SHARES shares < minShares"
py 'stock, index = ints(a[0]), ints(a[1]); preview = stock + [sum(index)]
before, after = ints(a[2]), ints(a[3])
print("    %-6s %16s %16s %14s" % ("token", "previewed", "taken", "returned wei"))
for k, sym in enumerate(a[4].split()):
    taken = before[k] - after[k]
    print("    %-6s %16s %16s %14s" % (sym, tok(preview[k]), tok(taken), preview[k] - taken))' \
  "$STOCK_AMTS" "$INDEX_AMTS" "$BAL_BEFORE" "$BAL_AFTER" "${TOKEN_SYMS[*]}"
info "deposit gas used: $DEPOSIT_GAS (block $(rint "$R" blockNumber)); ALICE minted $SHARES shares (minShares $MIN_SHARES)"

banner "Vault after the deposit: nav, allocations vs targets, rangeStatus, holdings, the ten positions"
NAV1=$(c1 "$VAULT" "nav()(uint256)")
SUPPLY1=$(c1 "$VAULT" "totalSupply()(uint256)")
py 'sys.exit(0 if abs(int(a[1]) - int(a[0]) - int(a[2])) * 100 <= int(a[2]) else 1)' "$NAV0" "$NAV1" "$DEPOSIT_VALUE" ||
  die "nav moved by $NAV1 - $NAV0, not within 1% of the deposited value"
info "nav() = $(py 'print(tok(a[0]))' "$NAV1") QQQ; totalSupply() = $SUPPLY1; balanceOf(ALICE) = $SHARES"
ALLOC=$(cj "$VAULT" "allocations()(uint256[],uint16[],bool[])")
py 'syms, targets = a[0].split(), ints(a[1]); value, bps, band = json.loads(a[2])
print("    %-6s %14s %8s %8s  %s" % ("pool", "value (QQQ)", "bps", "target", "in band (25% of target)"))
for k, s in enumerate(syms):
    print("    %-6s %14s %8d %8d  %s" % (s, tok(value[k]), int(bps[k]), targets[k], band[k]))
sys.exit(0 if all(band) or a[3] != "0" else 1)' "${SYM[*]}" "$(IFS=,; echo "${TB[*]}")" "$ALLOC" "$SUPPLY0" ||
  die "the first deposit left a constituent out of its allocation band"
RANGE=$(cj "$VAULT" "rangeStatus()(int24[],int24[],int24[],uint16[])")
py 'syms = a[0].split(); tick, lower, upper, edge = json.loads(a[1])
print("    %-6s %8s %8s %8s  %s" % ("pool", "tick", "lower", "upper", "edgeProximityBps"))
for k, s in enumerate(syms):
    print("    %-6s %8d %8d %8d  %d" % (s, tick[k], lower[k], upper[k], edge[k]))
sys.exit(0 if all(lower[k] <= tick[k] < upper[k] for k in range(len(syms))) else 1)' "${SYM[*]}" "$RANGE" ||
  die "a pool's tick is outside its position's range"
HOLD=$(cj "$VAULT" "holdings()(uint256[],uint256[],uint256[],uint256)")
py 'syms = a[0].split(); ps, pi, idle, idle_index = json.loads(a[1])
print("    %-6s %16s %16s %10s" % ("pool", "position stock", "position QQQ", "idle stock"))
for k, s in enumerate(syms):
    print("    %-6s %16s %16s %10d" % (s, tok(ps[k]), tok(pi[k]), int(idle[k])))
print("    idle QQQ: %d wei" % int(idle_index))' "${SYM[*]}" "$HOLD"
info "position NFTs (PositionManager $POSM):"
TOKEN_IDS=""
for ((i = 0; i < N; i++)); do
  CV=$(cj "$VAULT" "constituent(uint256)((address,bytes32,uint256,uint16,int24,int24))" "$i")
  TID=$(py 'print(int(json.loads(a[0])[0][2]))' "$CV")
  [[ "$TID" != 0 ]] || die "${SYM[i]} has no position (tokenId 0)"
  OWNER=$(c1 "$POSM" "ownerOf(uint256)(address)" "$TID")
  [[ "$(lc "$OWNER")" == "$(lc "$VAULT")" ]] || die "${SYM[i]}'s position $TID is owned by $OWNER, not the vault"
  PLIQ=$(c1 "$POSM" "getPositionLiquidity(uint256)(uint128)" "$TID")
  [[ "$PLIQ" != 0 ]] || die "${SYM[i]}'s position $TID has no liquidity"
  TOKEN_IDS+="$TID "
  info "  $(printf '%-6s tokenId %-7s ownerOf = vault  liquidity %s' "${SYM[i]}" "$TID" "$PLIQ")"
done
NUNIQ=$(printf '%s\n' $TOKEN_IDS | sort -u | wc -l | tr -d ' ')
[[ "$NUNIQ" == "$N" ]] || die "the constituents share token ids: $TOKEN_IDS"

# ------------------------------------------------------------------------------------------------------------ 2. swap
banner "Swap: ALICE sells 0.5 NVDA for QQQ through the NVDA/QQQ pool (exact input, PoolSwapTest settling ALICE's tokens)"
send "$ALICE" "${STOCK[NV]}" "approve(address,uint256)" "$ROUTER" "$MAX_UINT" >/dev/null
send "$ALICE" "$QQQ" "approve(address,uint256)" "$ROUTER" "$MAX_UINT" >/dev/null
S=$(slot0 "$NV")
read -r SP_BEFORE TICK_BEFORE <<<"$S"
FEE_BEFORE=$(get_fee "$NV")
NVB=$(c1 "${STOCK[NV]}" "balanceOf(address)(uint256)" "$ALICE")
QB=$(c1 "$QQQ" "balanceOf(address)(uint256)" "$ALICE")
if [[ "$NV_IS_0" == true ]]; then Z41=true LIMIT=$MIN_SQRT_PRICE_PLUS_ONE; else Z41=false LIMIT=$MAX_SQRT_PRICE_MINUS_ONE; fi
R=$(swap "$NV" "$Z41" "$SWAP_IN" "$LIMIT")
SWAP_GAS=$(rint "$R" gasUsed)
NVA=$(c1 "${STOCK[NV]}" "balanceOf(address)(uint256)" "$ALICE")
QA=$(c1 "$QQQ" "balanceOf(address)(uint256)" "$ALICE")
S=$(slot0 "$NV")
read -r SP_AFTER TICK_AFTER <<<"$S"
FEE_SAME_BLOCK=$(get_fee "$NV")
mine 1
FEE_NEXT_BLOCK=$(get_fee "$NV")
REF=$(fee_config "$NV" | awk '{print $4}')
py 'sys.exit(0 if int(a[0]) - int(a[1]) == int(a[2]) and int(a[3]) > int(a[4]) else 1)' "$NVB" "$NVA" "$SWAP_IN" "$QA" "$QB" ||
  die "the swap did not take exactly 0.5 NVDA for a positive amount of QQQ"
info "fees are (zeroForOne, oneForZero) in E6; NVDA is currency$([[ "$NV_IS_0" == true ]] && echo 0 || echo 1), so selling it is zeroForOne=$Z41"
info "before:              tick $TICK_BEFORE ($(py 'print(vs_ref(a[0], a[1]))' "$SP_BEFORE" "$REF") vs reference), getFee = ($(echo $FEE_BEFORE | tr ' ' ','))"
info "swap:                $(py 'print(tok(int(a[0]) - int(a[1])))' "$NVB" "$NVA") NVDA in, $(py 'print(tok(int(a[1]) - int(a[0])))' "$QB" "$QA") QQQ out, gas $SWAP_GAS"
info "after, same block:   tick $TICK_AFTER ($(py 'print(vs_ref(a[0], a[1]))' "$SP_AFTER" "$REF") vs reference), getFee = ($(echo $FEE_SAME_BLOCK | tr ' ' ',')) (the hook prices a block at its start-of-block price)"
info "after, next block:   getFee = ($(echo $FEE_NEXT_BLOCK | tr ' ' ','))"
py 'sys.exit(0 if (int(a[0]) < int(a[1])) == (a[2] == "true") else 1)' "$TICK_AFTER" "$TICK_BEFORE" "$Z41" ||
  die "selling NVDA did not move the tick its way ($TICK_BEFORE -> $TICK_AFTER)"

# ------------------------------------------------------------------------------------------------------------ 3. guard
banner "Deviation guard: push the NVDA pool exactly 2% below its reference with a swap; deposits must revert PriceDeviation($NV)"
TARGET=$(py 'print(math.isqrt(int(a[0]) ** 2 * 98 // 100))' "$REF")
NVB=$(c1 "${STOCK[NV]}" "balanceOf(address)(uint256)" "$ALICE")
swap_to "$NV" "$TARGET"
NVA=$(c1 "${STOCK[NV]}" "balanceOf(address)(uint256)" "$ALICE")
info "NVDA pool at sqrtPriceX96 $TARGET ($(py 'print(vs_ref(a[0], a[1]))' "$TARGET" "$REF") vs reference); the push sold $(py 'print(tok(int(a[0]) - int(a[1])))' "$NVB" "$NVA") NVDA"
expect_revert "previewDeposit(20 QQQ)" "PriceDeviation($NV)" \
  cast call --rpc-url "$LOCAL" "$VAULT" "previewDeposit(uint256)(uint256[],uint256[],uint256)" "$DEPOSIT_VALUE"
expect_revert "deposit(previewed amounts) from ALICE" "PriceDeviation($NV)" \
  cast send --rpc-url "$LOCAL" --unlocked --from "$ALICE" "$VAULT" "deposit(uint256[],uint256[],uint256,address)" \
  "[$STOCK_AMTS]" "[$INDEX_AMTS]" 0 "$ALICE"
QB=$(c1 "$QQQ" "balanceOf(address)(uint256)" "$ALICE")
NVB=$(c1 "${STOCK[NV]}" "balanceOf(address)(uint256)" "$ALICE")
swap_to "$NV" "$REF"
QA=$(c1 "$QQQ" "balanceOf(address)(uint256)" "$ALICE")
NVA=$(c1 "${STOCK[NV]}" "balanceOf(address)(uint256)" "$ALICE")
info "restored: the NVDA pool is back at its reference, ALICE bought $(py 'print(tok(int(a[1]) - int(a[0])))' "$NVB" "$NVA") NVDA for $(py 'print(tok(int(a[0]) - int(a[1])))' "$QB" "$QA") QQQ (the corrective side pays the decaying fee)"
cj "$VAULT" "previewDeposit(uint256)(uint256[],uint256[],uint256)" "$DEPOSIT_VALUE" >/dev/null ||
  die "previewDeposit still reverts after the NVDA pool is back at its reference"
info "previewDeposit(20 QQQ) succeeds again"
mine 1
FEE_IN_BAND=$(get_fee "$NV")
info "getFee at the reference (in band): ($(echo $FEE_IN_BAND | tr ' ' ','))"

# ------------------------------------------------------------------------------------------------------------ 4. shock
banner "Reference shock: NVDA's reference +2% in price (sqrt x 1.00995) via batchUpdateFeeConfig as the impersonated deployer"
FC=$(fee_config "$NV")
read -r K OPT MULT REF <<<"$FC"
NEWREF=$(py 'print(int(a[0]) * 100995 // 100000)' "$REF")
R=$(set_reference "$NV" "$NEWREF")
SHOCK_BN=$(rint "$R" blockNumber)
[[ "$(fee_config "$NV" | awk '{print $4}')" == "$NEWREF" ]] || die "the reference did not move to $NEWREF"
S=$(slot0 "$NV")
read -r SP TICK <<<"$S"
BELOW=$(py 'print("true" if int(a[0]) < int(a[1]) else "false")' "$SP" "$NEWREF")
info "feeConfig = (k $K, optimalFeeE6 $OPT, targetMultiplier $MULT); reference $REF -> $NEWREF ($(py 'print(vs_ref(a[1], a[0]))' "$REF" "$NEWREF") in price)"
info "the pool now sits $(py 'print(vs_ref(a[0], a[1]))' "$SP" "$NEWREF") vs the new reference: corrective = $([[ "$BELOW" == true ]] && echo oneForZero || echo zeroForOne), adverse = $([[ "$BELOW" == true ]] && echo zeroForOne || echo oneForZero)"
expect_revert "previewDeposit(20 QQQ) during the shock" "PriceDeviation($NV)" \
  cast call --rpc-url "$LOCAL" "$VAULT" "previewDeposit(uint256)(uint256[],uint256[],uint256)" "$DEPOSIT_VALUE"
F=$(get_fee "$NV")
B=$(block)
DECAY="0 $B $F"
DONE=0
for m in $SHOCK_BLOCKS; do
  mine $((m - DONE))
  DONE=$m
  F=$(get_fee "$NV")
  B=$(block)
  DECAY+=$'\n'"$m $B $F"
done
py 'below = a[0] == "true"; inband = ints(a[1].replace(" ", ","))
print("    %18s %10s %16s %16s" % ("blocks after shock", "block", "fee zeroForOne", "fee oneForZero"))
corr = []
ok = True
for line in a[2].strip().splitlines():
    m, b, f01, f10 = (int(x) for x in line.split())
    adverse, corrective = (f01, f10) if below else (f10, f01)
    corr.append(corrective)
    ok = ok and adverse == 0
    print("    %18d %10d %16s %16s" % (m, b, "%d (%s)" % (f01, pct(f01)), "%d (%s)" % (f10, pct(f10))))
inband_corr = inband[1] if below else inband[0]
ok = ok and corr[0] > inband_corr and all(x >= y for x, y in zip(corr, corr[1:])) and corr[-1] < corr[0]
if not ok:
    print("    adverse must be 0 and corrective start above its in-band %d and decay" % inband_corr, file=sys.stderr)
sys.exit(0 if ok else 1)' "$BELOW" "$FEE_IN_BAND" "$DECAY" || die "getFee did not behave as a reference shock should"
info "shock at block $SHOCK_BN: adverse side 0 throughout, corrective side starts high and decays by k = $(py 'print("%.6f" % (int(a[0]) / 2**24))' "$K") per block"

banner "Restore NVDA's original reference the same way; getFee must return to its in-band values"
R=$(set_reference "$NV" "$REF")
[[ "$(fee_config "$NV" | awk '{print $4}')" == "$REF" ]] || die "the reference did not return to $REF"
FEE_RESTORED=$(get_fee "$NV")
[[ "$FEE_RESTORED" == "$FEE_IN_BAND" ]] || die "getFee = ($FEE_RESTORED) after the restore, not the in-band ($FEE_IN_BAND)"
cj "$VAULT" "previewDeposit(uint256)(uint256[],uint256[],uint256)" "$DEPOSIT_VALUE" >/dev/null ||
  die "previewDeposit reverts after the reference is restored"
info "getFee = ($(echo $FEE_RESTORED | tr ' ' ',')) = in band; previewDeposit(20 QQQ) succeeds"

# ------------------------------------------------------------------------------------------------------------ 5. redeem
banner "Redeem: ALICE redeems all her shares (minStock / minIndex = 99.5% of previewRedeem)"
SHARES=$(c1 "$VAULT" "balanceOf(address)(uint256)" "$ALICE")
PRV=$(cj "$VAULT" "previewRedeem(uint256)(uint256[],uint256[])" "$SHARES")
MINS=$(py 'v = json.loads(a[0])
print(",".join(str(int(x) * 995 // 1000) for x in v[0]), ",".join(str(int(x) * 995 // 1000) for x in v[1]))' "$PRV")
read -r MIN_STOCK MIN_INDEX <<<"$MINS"
BAL_BEFORE=$(balances "$ALICE")
R=$(send "$ALICE" "$VAULT" "redeem(uint256,uint256[],uint256[],address)" "$SHARES" "[$MIN_STOCK]" "[$MIN_INDEX]" "$ALICE")
REDEEM_GAS=$(rint "$R" gasUsed)
BAL_AFTER=$(balances "$ALICE")
NAV2=$(c1 "$VAULT" "nav()(uint256)")
SUPPLY2=$(c1 "$VAULT" "totalSupply()(uint256)")
SHARES2=$(c1 "$VAULT" "balanceOf(address)(uint256)" "$ALICE")
py 'stock_out, index_out = json.loads(a[0]); before, after = ints(a[1]), ints(a[2]); syms = a[3].split()
preview = [int(x) for x in stock_out] + [sum(int(x) for x in index_out)]
print("    %-6s %16s %16s %16s" % ("token", "previewRedeem", "received", "over preview"))
ok = True
for k, s in enumerate(syms):
    got = after[k] - before[k]
    ok = ok and got * 1000 >= preview[k] * 995
    print("    %-6s %16s %16s %16s" % (s, tok(preview[k]), tok(got), tok(got - preview[k])))
sys.exit(0 if ok else 1)' "$PRV" "$BAL_BEFORE" "$BAL_AFTER" "${TOKEN_SYMS[*]}" || die "ALICE received less than 99.5% of previewRedeem"
[[ "$SHARES2" == 0 ]] || die "ALICE still holds $SHARES2 shares"
py 'sys.exit(0 if int(a[1]) - int(a[0]) < 10**16 else 1)' "$NAV0" "$NAV2" || die "nav() after the redeem is $NAV2 (was $NAV0 before the deposit)"
info "redeemed $SHARES shares, gas used $REDEEM_GAS; nav() after = $NAV2 wei (before the deposit: $NAV0); totalSupply() = $SUPPLY2"

# ------------------------------------------------------------------------------------------------------------ done
banner "Rehearsal passed on a fork of 4663 at block $FORK_BN"
info "deposit: gas $DEPOSIT_GAS (first deposit: $([[ "$SUPPLY0" == 0 ]] && echo yes || echo no)), $N positions owned by the vault (token ids ${TOKEN_IDS% }), nav $(py 'print(tok(a[0]))' "$NAV1") QQQ"
info "swap: 0.5 NVDA, tick $TICK_BEFORE -> $TICK_AFTER, getFee ($(echo $FEE_BEFORE | tr ' ' ',')) -> ($(echo $FEE_NEXT_BLOCK | tr ' ' ',')) next block"
info "deviation guard: PriceDeviation($NV) with the pool 2% off its reference, and again during the reference shock"
CORR=$(py 'print(" -> ".join(l.split()[3 if a[0] == "true" else 2] for l in a[1].strip().splitlines()))' "$BELOW" "$DECAY")
info "shock: corrective getFee $CORR over $(echo 0 $SHOCK_BLOCKS | tr ' ' '/') blocks; restored to ($(echo $FEE_RESTORED | tr ' ' ','))"
info "redeem: gas $REDEEM_GAS, nav after $NAV2 wei, ALICE shares 0"
