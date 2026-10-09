/**
 * Empty-pool aligner: moves each index pool that has no liquidity yet onto its StablePairHook reference, so
 * IndexLpVault's deposit guard cannot trip on a stale empty pool.
 *
 * bun run src/alignPools.ts [--deployments <file>] [--swapper <PoolSwapTest address>] [--min-bps 25] [--interval 60]
 *   [--dry-run] [--once]
 *
 * The keeper moves each pool's feeConfig(poolId).referenceSqrtPriceX96 with USD prices, but an empty pool's price moves
 * only when someone swaps, so it drifts; the vault's deposit and previewDeposit revert PriceDeviation(i) once a pool is
 * more than maxDeviationBps (100) off its reference. In an empty pool a swap moves the price for free: exact input 1 wei
 * (amountSpecified -1) limited at sqrtPriceLimitX96 = the reference takes no tokens and stops exactly on the limit. A
 * pass reads each pool's slot0, liquidity and reference, swaps every empty pool more than --min-bps off
 * ((spot / reference)^2 - 1) through v4-core's PoolSwapTest at --swapper, then re-reads it at the receipt's block and
 * requires it within 1 bps. A pool with liquidity is never swapped: it is logged as skipped, needing an arbitrage.
 *
 * Run it before the first deposit, and whenever the page shows "price off reference" for a pool that is still empty:
 * --dry-run --once prints the plan and the calldata, --once aligns, and without --once a pass runs every --interval
 * seconds. The swapper is deployed once, from the repo root, for the deployments file's PoolManager (keep
 * --constructor-args last: it takes every argument after it, --rpc-url and --broadcast included):
 *   forge create lib/v4-core/src/test/PoolSwapTest.sol:PoolSwapTest --rpc-url $RPC_4663 --account <keystore> \
 *     --password-file <file> --broadcast --constructor-args <poolManager>
 * On an anvil fork, answer ArbSys at 0x64 first, as tooling/fork/rehearsal.sh does: the hook's beforeSwap reads
 * arbBlockNumber(), so without it every swap simulation reverts WrappedError(hook, beforeSwap, 0x, HookCallFailed).
 *
 * RPC_4663 (required) is the chain 4663 RPC. DEPLOYER_KEY_FILE (default ~/.uniswap-hackathon/deployer.key) holds the
 * signer's hex private key; it is read only without --dry-run, and the signer needs gas only (no role, tokens or
 * approvals). A live run first checks that --swapper is a PoolSwapTest of that PoolManager; a dry run never reads it.
 * --once exits 1 when the pass fails or leaves an empty pool off its reference; a dry run exits 0 once it has printed.
 */
import { existsSync, readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { parseArgs } from "node:util";
import {
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  getAddress,
  http,
  isAddress,
  parseAbi,
  type Address,
  type Chain,
  type ContractFunctionArgs,
  type Hex,
  type PrivateKeyAccount,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { robinhood } from "viem/chains";
import { CHAIN_ID, DYNAMIC_FEE_FLAG } from "./constituents";
import { poolIdOf } from "./exportForWeb";
import { stablePairHookAbi } from "./hookAbi";
import { DEFAULT_DEPLOYMENTS, describeError, keyFilePath, loadAccount, parseDeployments } from "./keeper";
import { tickFromSqrtPriceX96 } from "./sqrtPrice";

export const DEFAULT_MIN_BPS = 25;
/** After its swap an empty pool must be within this many bps of its reference (the price lands on the limit: 0). */
export const VERIFY_BPS = 1;
export const SKIP_REASON = "pool has liquidity (needs an arbitrage, not a free reprice)";
const MIN_INTERVAL_S = 1;
const MAX_INTERVAL_S = 86_400;
const RPC_TIMEOUT_MS = 10_000;
const RECEIPT_TIMEOUT_MS = 60_000;
const BPS = 10_000n;
/** Deviations are compared with a bound exactly, in millionths of a bps (as the keeper compares moves). */
const DEVIATION_SCALE = 1_000_000n;

/** getSlot0 and getLiquidity of v4-periphery's StateView (src/lens/StateView.sol), PoolId as bytes32. */
export const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
]);

/**
 * v4-core's PoolSwapTest router (src/test/PoolSwapTest.sol): PoolKey (src/types/PoolKey.sol) with Currency and IHooks
 * as addresses, SwapParams (src/types/PoolOperation.sol), BalanceDelta as int256, manager() from PoolTestBase. The
 * errors are v4-core's (src/libraries/Pool.sol, src/interfaces/IPoolManager.sol, src/libraries/CustomRevert.sol), so
 * a failed simulation decodes to a name instead of a bare selector.
 */
export const poolSwapTestAbi = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }",
  "struct TestSettings { bool takeClaims; bool settleUsingBurn; }",
  "function swap(PoolKey key, SwapParams params, TestSettings testSettings, bytes hookData) payable returns (int256 delta)",
  "function manager() view returns (address)",
  "error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96)",
  "error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96)",
  "error PoolNotInitialized()",
  "error SwapAmountCannotBeZero()",
  "error CurrencyNotSettled()",
  "error WrappedError(address target, bytes4 selector, bytes reason, bytes details)",
]);

/** The arguments of PoolSwapTest.swap: key, params, test settings, hook data. */
export type SwapArgs = ContractFunctionArgs<typeof poolSwapTestAbi, "payable", "swap">;
export type PoolKey = SwapArgs[0];

/** A pool the aligner can swap; its key hashes to its poolId (checked when the deployments file is read). */
export interface AlignPool {
  symbol: string;
  poolId: Hex;
  key: PoolKey;
}

export interface AlignDeployments {
  hook: Address;
  stateView: Address;
  poolManager: Address;
  pools: AlignPool[];
}

/** One pool's state: StateView's slot0 price and active liquidity, and the hook's reference. */
export interface PoolReading {
  poolId: Hex;
  sqrtPriceX96: bigint;
  liquidity: bigint;
  referenceSqrtPriceX96: bigint;
}

export interface Alignment {
  symbol: string;
  poolId: Hex;
  spot: bigint;
  reference: bigint;
  liquidity: bigint;
  /** (spot / reference)^2 - 1: the pool price off its reference, in bps truncated toward zero to a millionth. */
  deviationBps: number;
  /** swap: empty and more than minBps off; skip: has liquidity and more than minBps off; none: within minBps. */
  action: "swap" | "skip" | "none";
  /** Why the pool is skipped. */
  reason?: string;
  /** The PoolSwapTest.swap arguments that move the empty pool's price onto its reference. */
  swap?: SwapArgs;
}

type PlannedAlignment = Alignment & { swap: SwapArgs };

/** The pool price's deviation from the reference, (spot / reference)^2 - 1, in bps truncated toward zero to 1e-6. */
export function deviationBps(spot: bigint, reference: bigint): number {
  if (reference <= 0n) throw new Error(`the reference must be positive, got ${reference}`);
  const ref2 = reference * reference;
  return Number(((spot * spot - ref2) * BPS * DEVIATION_SCALE) / ref2) / Number(DEVIATION_SCALE);
}

/** |(spot / reference)^2 - 1| > bps / 10000, compared exactly in millionths of a bps. */
function exceedsBps(spot: bigint, reference: bigint, bps: number): boolean {
  const [spot2, ref2] = [spot * spot, reference * reference];
  const bound = BigInt(Math.round(bps * Number(DEVIATION_SCALE)));
  return (spot2 > ref2 ? spot2 - ref2 : ref2 - spot2) * BPS * DEVIATION_SCALE > bound * ref2;
}

/**
 * What to do with each pool, matched to its reading by poolId: an empty pool more than minBps off gets the exact-input
 * 1 wei swap limited at its reference (zeroForOne when its price is above it), a pool with liquidity more than minBps
 * off is skipped, and any pool within minBps (a deviation of exactly minBps included) is left alone.
 */
export function planAlignments(
  pools: readonly AlignPool[],
  readings: readonly PoolReading[],
  minBps: number,
): Alignment[] {
  if (!Number.isFinite(minBps) || minBps < 0) throw new Error(`minBps must be a non-negative number, got ${minBps}`);
  const byId = new Map(readings.map((r) => [r.poolId.toLowerCase(), r]));
  return pools.map((pool): Alignment => {
    const at = `${pool.symbol} ${pool.poolId}`;
    const reading = byId.get(pool.poolId.toLowerCase());
    if (reading === undefined) throw new Error(`no reading for pool ${at}`);
    const { sqrtPriceX96: spot, liquidity, referenceSqrtPriceX96: reference } = reading;
    if (spot <= 0n) throw new Error(`pool ${at} is not initialized (its slot0 price is 0)`);
    if (reference <= 0n) throw new Error(`pool ${at} has no reference on the hook (its feeConfig is empty)`);
    const { symbol, poolId } = pool;
    const alignment = { symbol, poolId, spot, reference, liquidity, deviationBps: deviationBps(spot, reference) };
    if (!exceedsBps(spot, reference, minBps)) return { ...alignment, action: "none" };
    if (liquidity !== 0n) return { ...alignment, action: "skip", reason: SKIP_REASON };
    const params = { zeroForOne: spot > reference, amountSpecified: -1n, sqrtPriceLimitX96: reference };
    const settings = { takeClaims: false, settleUsingBurn: false };
    return { ...alignment, action: "swap", swap: [pool.key, params, settings, "0x"] };
  });
}

const signedBps = (bps: number) => `${bps >= 0 ? "+" : ""}${bps.toFixed(2)}`;
const emptyPools = (n: number) => `${n} empty pool${n === 1 ? "" : "s"}`;

/** The log line for one pool; a skipped pool is a WARN. */
export function formatAlignment(a: Alignment, minBps: number): string {
  const price = (sqrtPriceX96: bigint) => `${sqrtPriceX96} (tick ${tickFromSqrtPriceX96(sqrtPriceX96)})`;
  const line =
    `${a.symbol} ${a.poolId} liquidity ${a.liquidity}, spot ${price(a.spot)}, reference ${price(a.reference)}: ` +
    `price ${signedBps(a.deviationBps)} bps off`;
  if (a.action === "skip") return `WARN ${line}, beyond ${minBps} bps: skipped: ${a.reason}`;
  if (a.action === "none") return `${line}, within ${minBps} bps: keep`;
  const direction = a.swap?.[1].zeroForOne ? "zeroForOne" : "oneForZero";
  return `${line}, beyond ${minBps} bps and empty: swap ${direction} onto the reference`;
}

/**
 * The keeper's reading of the deployments file plus what a swap needs: StateView, the PoolManager and each pool's
 * key, which must hash to its poolId. Throws naming the first bad field.
 */
export function parseAlignDeployments(raw: unknown): AlignDeployments {
  const { hook, pools } = parseDeployments(raw);
  const { stateView, poolManager, constituents } = raw as Record<string, unknown>;
  function address(value: unknown, field: string): Address {
    if (typeof value !== "string" || !isAddress(value, { strict: false })) {
      throw new Error(`deployments: ${field} is not an address`);
    }
    return getAddress(value);
  }
  return {
    hook,
    stateView: address(stateView, "stateView"),
    poolManager: address(poolManager, "poolManager"),
    pools: pools.map((pool, i): AlignPool => {
      const at = `constituents[${i}] (${pool.symbol})`;
      const { tickSpacing } = ((constituents as unknown[])[i] ?? {}) as Record<string, unknown>;
      if (
        typeof tickSpacing !== "number" ||
        !Number.isInteger(tickSpacing) ||
        tickSpacing < 1 ||
        tickSpacing > 32_767
      ) {
        throw new Error(`deployments: ${at}.tickSpacing must be an integer from 1 to 32767`);
      }
      const { symbol, poolId, currency0, currency1 } = pool;
      const id = poolIdOf(currency0, currency1, tickSpacing, hook);
      if (id !== poolId.toLowerCase()) {
        throw new Error(`deployments: ${at}: poolId ${poolId} is not the id of its pool key, expected ${id}`);
      }
      return { symbol, poolId, key: { currency0, currency1, fee: DYNAMIC_FEE_FLAG, tickSpacing, hooks: hook } };
    }),
  };
}

export function loadAlignDeployments(path: string): AlignDeployments {
  if (!existsSync(path)) throw new Error(`no deployments file at ${path}; deploy first or pass --deployments <file>`);
  const text = readFileSync(path, "utf8");
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (error) {
    throw new Error(`${path} is not valid JSON: ${describeError(error)}`);
  }
  return parseAlignDeployments(raw);
}

export interface AlignOptions {
  deployments: string;
  /** The PoolSwapTest to swap through: a live run needs it, a dry run only prints it. */
  swapper?: Address;
  minBps: number;
  intervalMs: number;
  dryRun: boolean;
  once: boolean;
}

export function parseCli(args: readonly string[]): AlignOptions {
  const { values } = parseArgs({
    args: [...args],
    options: {
      deployments: { type: "string", default: DEFAULT_DEPLOYMENTS },
      swapper: { type: "string" },
      "min-bps": { type: "string", default: String(DEFAULT_MIN_BPS) },
      interval: { type: "string", default: "60" },
      "dry-run": { type: "boolean", default: false },
      once: { type: "boolean", default: false },
    },
  });
  const toNumber = (text: string) => (text.trim() === "" ? Number.NaN : Number(text));
  const minBps = toNumber(values["min-bps"]);
  if (!Number.isFinite(minBps) || minBps < 0) {
    throw new Error(`--min-bps must be a non-negative number, got ${values["min-bps"]}`);
  }
  const interval = toNumber(values.interval);
  if (!(interval >= MIN_INTERVAL_S && interval <= MAX_INTERVAL_S)) {
    throw new Error(
      `--interval must be between ${MIN_INTERVAL_S} and ${MAX_INTERVAL_S} seconds, got ${values.interval}`,
    );
  }
  const { swapper } = values;
  if (swapper !== undefined && !isAddress(swapper, { strict: false })) {
    throw new Error(`--swapper must be an address, got ${swapper}`);
  }
  return {
    deployments: values.deployments,
    swapper: swapper === undefined ? undefined : getAddress(swapper),
    minBps,
    intervalMs: interval * 1000,
    dryRun: values["dry-run"],
    once: values.once,
  };
}

export interface AlignDeps {
  client: PublicClient;
  /** The signer's client; a dry run never touches it. */
  wallet?: WalletClient<Transport, Chain, PrivateKeyAccount>;
  log: (line: string) => void;
}

export interface PassResult {
  alignments: Alignment[];
  /** The empty pools swapped onto their reference and found there at the receipt's block. */
  aligned: string[];
  /** The empty pools a live pass left off their reference: the swap failed or did not land within VERIFY_BPS. */
  failed: string[];
  /** The pools more than minBps off their reference that have liquidity, so were not swapped. */
  skipped: string[];
}

/** One pool's reading, at `blockNumber` when given; errors name the pool, the call and the contract. */
async function readPool(
  client: PublicClient,
  stateView: Address,
  pool: AlignPool,
  blockNumber?: bigint,
): Promise<PoolReading> {
  const { poolId } = pool;
  const at = blockNumber === undefined ? {} : { blockNumber };
  const named = <T>(call: string, address: Address, read: Promise<T>) =>
    read.catch((error: unknown) => {
      throw new Error(`${call} of ${pool.symbol} ${poolId} on ${address}: ${describeError(error)}`);
    });
  const [[sqrtPriceX96], liquidity, [, , , referenceSqrtPriceX96]] = await Promise.all([
    named(
      "getSlot0",
      stateView,
      client.readContract({ address: stateView, abi: stateViewAbi, functionName: "getSlot0", args: [poolId], ...at }),
    ),
    named(
      "getLiquidity",
      stateView,
      client.readContract({
        address: stateView,
        abi: stateViewAbi,
        functionName: "getLiquidity",
        args: [poolId],
        ...at,
      }),
    ),
    named(
      "feeConfig",
      pool.key.hooks,
      client.readContract({
        address: pool.key.hooks,
        abi: stablePairHookAbi,
        functionName: "feeConfig",
        args: [poolId],
        ...at,
      }),
    ),
  ]);
  return { poolId, sqrtPriceX96, liquidity, referenceSqrtPriceX96 };
}

/** Simulates the swap, sends it, waits for it and re-reads the pool at its block; throws unless it is aligned. */
async function sendAlignment(
  a: PlannedAlignment,
  swapper: Address,
  stateView: Address,
  { client, wallet, log }: Required<AlignDeps>,
) {
  const { request } = await client.simulateContract({
    account: wallet.account,
    address: swapper,
    abi: poolSwapTestAbi,
    functionName: "swap",
    args: a.swap,
  });
  const hash = await wallet.writeContract(request);
  log(`sent swap on ${swapper} moving ${a.symbol} onto its reference: ${hash}`);
  const receipt = await client.waitForTransactionReceipt({ hash, timeout: RECEIPT_TIMEOUT_MS });
  if (receipt.status !== "success") throw new Error(`${hash} reverted in block ${receipt.blockNumber}`);
  const pool = { symbol: a.symbol, poolId: a.poolId, key: a.swap[0] };
  const after = await readPool(client, stateView, pool, receipt.blockNumber);
  const off = signedBps(deviationBps(after.sqrtPriceX96, after.referenceSqrtPriceX96));
  if (exceedsBps(after.sqrtPriceX96, after.referenceSqrtPriceX96, VERIFY_BPS)) {
    const limit = a.swap[1].sqrtPriceLimitX96;
    const why =
      after.sqrtPriceX96 === limit
        ? `its price is on the planned ${limit}, but the reference moved to ${after.referenceSqrtPriceX96}`
        : `its price stopped at ${after.sqrtPriceX96}, not the planned ${limit}`;
    throw new Error(`price ${off} bps off its reference after ${hash} (block ${receipt.blockNumber}): ${why}`);
  }
  log(`confirmed ${hash} in block ${receipt.blockNumber}: ${a.symbol} price ${off} bps off its reference`);
}

/**
 * One pass: read every pool, plan, log each decision, then print (dry run) or send each swap. A failed swap is logged
 * and the next pool still goes; the result names the pools left off their reference.
 */
export async function alignPass(
  deployments: AlignDeployments,
  options: Pick<AlignOptions, "minBps" | "dryRun" | "swapper">,
  { client, wallet, log }: AlignDeps,
): Promise<PassResult> {
  const { minBps, dryRun, swapper } = options;
  const readings = await Promise.all(deployments.pools.map((pool) => readPool(client, deployments.stateView, pool)));
  const alignments = planAlignments(deployments.pools, readings, minBps);
  for (const a of alignments) log(formatAlignment(a, minBps));
  const skipped = alignments.filter((a) => a.action === "skip").map((a) => a.symbol);
  const result: PassResult = { alignments, aligned: [], failed: [], skipped };
  const skippedNote = skipped.length === 0 ? "" : `; skipped, having liquidity: ${skipped.join(", ")}`;
  const planned = alignments.filter((a): a is PlannedAlignment => a.swap !== undefined);
  if (planned.length === 0) {
    log(`no empty pool more than ${minBps} bps off its reference; nothing to send${skippedNote}`);
    return result;
  }
  if (dryRun) {
    for (const a of planned) {
      const { zeroForOne, amountSpecified, sqrtPriceLimitX96 } = a.swap[1];
      const params = `zeroForOne ${zeroForOne}, amountSpecified ${amountSpecified}, sqrtPriceLimitX96 ${sqrtPriceLimitX96}`;
      log(`dry run, not sent: swap for ${a.symbol} (${params}) on ${swapper ?? "the --swapper"}`);
      log(`calldata ${encodeFunctionData({ abi: poolSwapTestAbi, functionName: "swap", args: a.swap })}`);
    }
    log(`dry run: ${emptyPools(planned.length)} to align, nothing sent${skippedNote}`);
    return result;
  }
  if (!wallet || !swapper) {
    throw new Error("no signer or swapper to send with; pass --dry-run, or --swapper and DEPLOYER_KEY_FILE");
  }
  for (const a of planned) {
    try {
      await sendAlignment(a, swapper, deployments.stateView, { client, wallet, log });
      result.aligned.push(a.symbol);
    } catch (error) {
      log(`FAIL ${a.symbol} ${a.poolId}: ${describeError(error)}`);
      result.failed.push(a.symbol);
    }
  }
  const left = result.failed.length === 0 ? "" : `; left off their reference: ${result.failed.join(", ")}`;
  log(`aligned ${result.aligned.length} of ${emptyPools(planned.length)}${left}${skippedNote}`);
  return result;
}

/** Refuses a --swapper that is not a PoolSwapTest of `poolManager`: a swap through it would move nothing. */
export async function checkSwapper(client: PublicClient, swapper: Address, poolManager: Address): Promise<void> {
  const code = await client.getCode({ address: swapper });
  if (code === undefined || code === "0x") throw new Error(`no contract at --swapper ${swapper}; deploy PoolSwapTest`);
  let manager: Address;
  try {
    manager = await client.readContract({ address: swapper, abi: poolSwapTestAbi, functionName: "manager" });
  } catch (error) {
    throw new Error(`--swapper ${swapper} is not a PoolSwapTest: manager() failed: ${describeError(error)}`);
  }
  if (getAddress(manager) !== getAddress(poolManager)) {
    throw new Error(`--swapper ${swapper} swaps on PoolManager ${manager}, not the deployments file's ${poolManager}`);
  }
}

const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);

async function main(argv: readonly string[]): Promise<number> {
  const options = parseCli(argv);
  const deployments = loadAlignDeployments(options.deployments);
  const rpcUrl = process.env.RPC_4663;
  if (!rpcUrl) throw new Error("RPC_4663 is not set; point it at a chain 4663 RPC");
  const { swapper } = options;
  if (!options.dryRun && swapper === undefined) {
    throw new Error(
      "a live run needs --swapper <PoolSwapTest address> (see the header to deploy one), or pass --dry-run",
    );
  }
  const account = options.dryRun ? undefined : loadAccount(keyFilePath());
  const transport = http(rpcUrl, { timeout: RPC_TIMEOUT_MS });
  const client = createPublicClient({ chain: robinhood, transport });
  const wallet = account && createWalletClient({ account, chain: robinhood, transport });
  const cadence = options.once ? "once" : `every ${options.intervalMs / 1000} s`;
  log(
    `aligner: hook ${deployments.hook}, ${deployments.pools.length} pools, min ${options.minBps} bps, ` +
      `swapper ${swapper ?? "none"}, ${cadence}, ${account ? `signer ${account.address}` : "dry run"}`,
  );
  const chainId = await client.getChainId();
  if (chainId !== CHAIN_ID) throw new Error(`RPC_4663 serves chain ${chainId}, expected ${CHAIN_ID}`);
  if (!options.dryRun && swapper !== undefined) await checkSwapper(client, swapper, deployments.poolManager);

  const deps: AlignDeps = { client, wallet, log };
  for (;;) {
    try {
      const { failed } = await alignPass(deployments, options, deps);
      if (options.once) return failed.length === 0 ? 0 : 1;
    } catch (error) {
      console.error(`${new Date().toISOString()} pass failed: ${describeError(error)}`);
      if (options.once) return 1;
    }
    await sleep(options.intervalMs);
  }
}

if (import.meta.main) {
  try {
    process.exitCode = await main(process.argv.slice(2));
  } catch (error) {
    console.error(`alignPools: ${describeError(error)}`);
    process.exitCode = 1;
  }
}
