/**
 * StablePairHook reference keeper: keeps each pool's referenceSqrtPriceX96 at the USD price ratio of its currencies,
 * so the hook's fee curve stays centred as prices move.
 *
 * bun run src/keeper.ts [--interval 60] [--threshold-bps 20] [--max-move-bps 2000] [--force] [--dry-run] [--once]
 *   [--deployments <file>]
 *
 * RPC_4663 (required) is the chain 4663 RPC. DEPLOYER_KEY_FILE (default ~/.uniswap-hackathon/deployer.key) holds the
 * signer's hex private key; it is read only without --dry-run and the signer needs CONFIG_MANAGER_ROLE on the hook.
 * A move above --max-move-bps is taken for a bad price and skipped with a WARN, unless --force.
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { parseArgs } from "node:util";
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  getAddress,
  http,
  isAddress,
  type Address,
  type Chain,
  type Hex,
  type PrivateKeyAccount,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { robinhood } from "viem/chains";
import { CHAIN_ID, INDEX_TOKEN } from "./constituents";
import { stablePairHookAbi } from "./hookAbi";
import { fetchUsdPrices, usdPrice, type UsdPrices } from "./prices";
import { computeReference, tickFromSqrtPriceX96 } from "./sqrtPrice";

export const DEFAULT_DEPLOYMENTS = join(import.meta.dir, "../deployments/4663.json");
export const DEFAULT_MAX_MOVE_BPS = 2000;
const DEFAULT_KEY_FILE = "~/.uniswap-hackathon/deployer.key";
const MIN_INTERVAL_S = 1;
const MAX_INTERVAL_S = 86_400;
const RPC_TIMEOUT_MS = 10_000;
const RECEIPT_TIMEOUT_MS = 60_000;
/** Moves are compared with the threshold and the max move exactly, in millionths of a bps. */
const MOVE_SCALE = 1_000_000n;

/** A pool's fee-curve centre: sqrt(currency1 per currency0) in Q96. */
export interface PoolReference {
  poolId: string;
  referenceSqrtPriceX96: bigint;
}

export interface Decision {
  poolId: string;
  current: bigint;
  fresh: bigint;
  /** |fresh / current - 1| x 2 x 10000: the move of the sqrt price, doubled into price bps. */
  moveBps: number;
  /** The move is above maxMoveBps, so the price is suspect: the pool is sent only with force. */
  exceedsMaxMove: boolean;
  update: boolean;
}

/** poolIds and configs are index-aligned: the arguments of batchUpdateFeeConfig. */
export interface Plan<T extends PoolReference> {
  poolIds: T["poolId"][];
  configs: Omit<T, "poolId">[];
  decisions: Decision[];
}

export interface PlanOptions {
  /** Moves above this many price bps are skipped as suspect prices; default DEFAULT_MAX_MOVE_BPS. */
  maxMoveBps?: number;
  /** Send moves above maxMoveBps anyway. */
  force?: boolean;
}

/**
 * The pools whose reference moved strictly more than thresholdBps in price, matched to `fresh` by poolId. A move
 * strictly above maxMoveBps is left out unless `force`; the other pools are planned regardless. Whatever else a
 * `current` entry carries (k, optimalFeeE6, targetMultiplier) passes into its config unchanged.
 */
export function planUpdates<T extends PoolReference>(
  current: readonly T[],
  fresh: readonly PoolReference[],
  thresholdBps: number,
  { maxMoveBps = DEFAULT_MAX_MOVE_BPS, force = false }: PlanOptions = {},
): Plan<T> {
  if (!Number.isFinite(thresholdBps) || thresholdBps < 0) {
    throw new Error(`thresholdBps must be a non-negative number, got ${thresholdBps}`);
  }
  if (!Number.isFinite(maxMoveBps) || maxMoveBps <= thresholdBps) {
    throw new Error(`maxMoveBps must be a finite number above thresholdBps (${thresholdBps}), got ${maxMoveBps}`);
  }
  const scaled = (bps: number) => BigInt(Math.round(bps * Number(MOVE_SCALE)));
  const [threshold, maxMove] = [scaled(thresholdBps), scaled(maxMoveBps)];
  const freshById = new Map(fresh.map((f) => [f.poolId.toLowerCase(), f.referenceSqrtPriceX96]));
  const plan: Plan<T> = { poolIds: [], configs: [], decisions: [] };
  for (const pool of current) {
    const { poolId, ...config } = pool;
    const cur = pool.referenceSqrtPriceX96;
    const next = freshById.get(poolId.toLowerCase());
    if (next === undefined) throw new Error(`no fresh reference for pool ${poolId}`);
    if (cur <= 0n) throw new Error(`pool ${poolId} has no reference on the hook (its feeConfig is empty)`);
    const scaledMove = (next > cur ? next - cur : cur - next) * 20_000n * MOVE_SCALE;
    const exceedsMaxMove = scaledMove > maxMove * cur;
    const update = scaledMove > threshold * cur && (force || !exceedsMaxMove);
    const moveBps = Number(scaledMove / cur) / Number(MOVE_SCALE);
    plan.decisions.push({ poolId, current: cur, fresh: next, moveBps, exceedsMaxMove, update });
    if (update) {
      plan.poolIds.push(poolId);
      plan.configs.push({ ...config, referenceSqrtPriceX96: next });
    }
  }
  return plan;
}

/** What the keeper reads from tooling/deployments/4663.json for each pool. */
export interface DeployedPool {
  symbol: string;
  stock: Address;
  poolId: Hex;
  currency0: Address;
  currency1: Address;
}

export interface Deployments {
  hook: Address;
  pools: DeployedPool[];
}

/** The reference each pool should have now: sqrt(usd(currency0) / usd(currency1)), as set at pool creation. */
export function freshReferences(
  pools: readonly DeployedPool[],
  prices: UsdPrices,
): { poolId: Hex; referenceSqrtPriceX96: bigint }[] {
  return pools.map((p) => ({
    poolId: p.poolId,
    referenceSqrtPriceX96: computeReference(usdPrice(prices, p.currency0), usdPrice(prices, p.currency1)),
  }));
}

const sameAddress = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** Validates the deployments file down to what the keeper reads; throws naming the first bad field. */
export function parseDeployments(raw: unknown): Deployments {
  function fail(message: string): never {
    throw new Error(`deployments: ${message}`);
  }
  function address(value: unknown, field: string): Address {
    if (typeof value !== "string" || !isAddress(value, { strict: false })) fail(`${field} is not an address`);
    return getAddress(value);
  }
  if (typeof raw !== "object" || raw === null) fail("not a JSON object");
  const { chainId, hook, constituents } = raw as Record<string, unknown>;
  if (chainId !== CHAIN_ID) fail(`chainId is ${JSON.stringify(chainId)}, expected ${CHAIN_ID}`);
  const hookAddress = address(hook, "hook");
  if (!Array.isArray(constituents) || constituents.length === 0) fail("constituents must be a non-empty array");
  const pools = constituents.map((entry: unknown, i): DeployedPool => {
    const { symbol, stock, poolId, currency0, currency1 } = (entry ?? {}) as Record<string, unknown>;
    if (typeof symbol !== "string" || symbol === "") fail(`constituents[${i}].symbol must be a non-empty string`);
    const at = `constituents[${i}] (${symbol})`;
    if (typeof poolId !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(poolId)) {
      fail(`${at}.poolId must be a 32-byte hex string`);
    }
    const pool = {
      symbol,
      stock: address(stock, `${at}.stock`),
      poolId: poolId as Hex,
      currency0: address(currency0, `${at}.currency0`),
      currency1: address(currency1, `${at}.currency1`),
    };
    if (pool.currency0.toLowerCase() >= pool.currency1.toLowerCase()) {
      fail(`${at}: currency0 must sort below currency1`);
    }
    const other = sameAddress(pool.currency0, INDEX_TOKEN)
      ? pool.currency1
      : sameAddress(pool.currency1, INDEX_TOKEN)
      ? pool.currency0
      : fail(`${at}: neither currency is ${INDEX_TOKEN}`);
    if (!sameAddress(other, pool.stock)) fail(`${at}: stock ${pool.stock} is not the pool's ${other}`);
    return pool;
  });
  return { hook: hookAddress, pools };
}

export function loadDeployments(path: string): Deployments {
  if (!existsSync(path)) throw new Error(`no deployments file at ${path}; deploy first or pass --deployments <file>`);
  const text = readFileSync(path, "utf8");
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (error) {
    throw new Error(`${path} is not valid JSON: ${describeError(error)}`);
  }
  return parseDeployments(raw);
}

export interface KeeperOptions {
  intervalMs: number;
  thresholdBps: number;
  maxMoveBps: number;
  force: boolean;
  dryRun: boolean;
  once: boolean;
  deployments: string;
}

export function parseCli(args: readonly string[]): KeeperOptions {
  const { values } = parseArgs({
    args: [...args],
    options: {
      interval: { type: "string", default: "60" },
      "threshold-bps": { type: "string", default: "20" },
      "max-move-bps": { type: "string", default: String(DEFAULT_MAX_MOVE_BPS) },
      force: { type: "boolean", default: false },
      "dry-run": { type: "boolean", default: false },
      once: { type: "boolean", default: false },
      deployments: { type: "string", default: DEFAULT_DEPLOYMENTS },
    },
  });
  const toNumber = (text: string) => (text.trim() === "" ? Number.NaN : Number(text));
  const interval = toNumber(values.interval);
  if (!(interval >= MIN_INTERVAL_S && interval <= MAX_INTERVAL_S)) {
    throw new Error(
      `--interval must be between ${MIN_INTERVAL_S} and ${MAX_INTERVAL_S} seconds, got ${values.interval}`,
    );
  }
  const thresholdBps = toNumber(values["threshold-bps"]);
  if (!Number.isFinite(thresholdBps) || thresholdBps < 0) {
    throw new Error(`--threshold-bps must be a non-negative number, got ${values["threshold-bps"]}`);
  }
  const maxMoveBps = toNumber(values["max-move-bps"]);
  if (!Number.isFinite(maxMoveBps) || maxMoveBps <= thresholdBps) {
    const got = values["max-move-bps"];
    throw new Error(`--max-move-bps must be a finite number above --threshold-bps (${thresholdBps}), got ${got}`);
  }
  return {
    intervalMs: interval * 1000,
    thresholdBps,
    maxMoveBps,
    force: values.force,
    dryRun: values["dry-run"],
    once: values.once,
    deployments: values.deployments,
  };
}

export function keyFilePath(env: Record<string, string | undefined> = process.env): string {
  return (env.DEPLOYER_KEY_FILE || DEFAULT_KEY_FILE).replace(/^~(?=$|\/)/, homedir());
}

/** The signer from a file holding a hex private key; errors name the file, never what is in it. */
export function loadAccount(path: string): PrivateKeyAccount {
  let text: string;
  try {
    text = readFileSync(path, "utf8").trim();
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code ?? "unreadable";
    throw new Error(`cannot read the signer key at ${path} (set DEPLOYER_KEY_FILE): ${code}`);
  }
  const key = text.startsWith("0x") ? text : `0x${text}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error(`${path} does not hold a 32-byte hex private key`);
  try {
    return privateKeyToAccount(key as Hex);
  } catch {
    // the curve library's message can include the key itself
    throw new Error(`${path} does not hold a valid secp256k1 private key`);
  }
}

/** One line for logs: viem's short message, with a decoded custom error, never a stack or viem's call dump. */
export function describeError(error: unknown): string {
  let message: string;
  if (error instanceof BaseError) {
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError);
    const custom = revert instanceof ContractFunctionRevertedError ? revert.data : undefined;
    if (custom && custom.errorName !== "Error" && custom.errorName !== "Panic") {
      const args = (custom.args ?? []).map(String).join(", ");
      message = `${error.shortMessage.replace(/\.$/, "")}: ${custom.errorName}(${args})`;
    } else {
      message = error.shortMessage;
      if (error.details && !message.includes(error.details)) message += ` (${error.details.slice(0, 200)})`;
    }
  } else {
    message = error instanceof Error ? error.message : String(error);
  }
  return message.replace(/\s+/g, " ").trim();
}

/** The log line for one pool; a move above maxMoveBps is a WARN saying whether it was skipped or forced. */
export function formatDecision(symbol: string, d: Decision, thresholdBps: number, maxMoveBps: number): string {
  const ref = (sqrtPriceX96: bigint) => `${sqrtPriceX96} (tick ${tickFromSqrtPriceX96(sqrtPriceX96)})`;
  const move = d.moveBps.toFixed(2);
  const line = `${symbol} ${d.poolId} reference ${ref(d.current)} -> ${ref(d.fresh)}, price move ${move}`;
  if (d.exceedsMaxMove) {
    const verdict = d.update ? "sent anyway (--force)" : "skipped as a suspect price, --force overrides";
    return `WARN ${line} bps > max ${maxMoveBps} bps: ${verdict}`;
  }
  return d.update ? `${line} > ${thresholdBps} bps: update` : `${line} <= ${thresholdBps} bps: keep`;
}

export interface TickDeps {
  client: PublicClient;
  /** The signer's client; a dry run never touches it. */
  wallet?: WalletClient<Transport, Chain, PrivateKeyAccount>;
  fetchPrices: (addresses: readonly Address[]) => Promise<UsdPrices>;
  log: (line: string) => void;
}

async function readFeeConfig(client: PublicClient, hook: Address, pool: DeployedPool) {
  try {
    const [k, optimalFeeE6, targetMultiplier, referenceSqrtPriceX96] = await client.readContract({
      address: hook,
      abi: stablePairHookAbi,
      functionName: "feeConfig",
      args: [pool.poolId],
    });
    return { poolId: pool.poolId, k, optimalFeeE6, targetMultiplier, referenceSqrtPriceX96 };
  } catch (error) {
    throw new Error(`feeConfig of ${pool.symbol} ${pool.poolId} on ${hook}: ${describeError(error)}`);
  }
}

/** One pass: read each pool's feeConfig, price the currencies, plan, log every decision, then print or send. */
export async function tick(
  { hook, pools }: Deployments,
  options: Pick<KeeperOptions, "thresholdBps" | "maxMoveBps" | "force" | "dryRun">,
  { client, wallet, fetchPrices, log }: TickDeps,
) {
  const { thresholdBps, maxMoveBps, force } = options;
  const [current, prices] = await Promise.all([
    Promise.all(pools.map((pool) => readFeeConfig(client, hook, pool))),
    fetchPrices([INDEX_TOKEN, ...pools.map((p) => p.stock)]),
  ]);
  const plan = planUpdates(current, freshReferences(pools, prices), thresholdBps, { maxMoveBps, force });
  const symbols = new Map(pools.map((p) => [p.poolId.toLowerCase(), p.symbol]));
  for (const d of plan.decisions) {
    log(formatDecision(symbols.get(d.poolId.toLowerCase()) ?? "?", d, thresholdBps, maxMoveBps));
  }
  if (plan.poolIds.length === 0) {
    log("no pool to update; nothing to send");
    return plan;
  }
  const args = [plan.poolIds, plan.configs] as const;
  const call = `batchUpdateFeeConfig on ${hook} for ${plan.poolIds.length} pools`;
  if (options.dryRun) {
    log(`dry run, not sent: ${call}`);
    log(`calldata ${encodeFunctionData({ abi: stablePairHookAbi, functionName: "batchUpdateFeeConfig", args })}`);
    return plan;
  }
  if (!wallet) throw new Error("no signer to send with; pass --dry-run or set DEPLOYER_KEY_FILE");
  const { request } = await client.simulateContract({
    account: wallet.account,
    address: hook,
    abi: stablePairHookAbi,
    functionName: "batchUpdateFeeConfig",
    args,
  });
  const hash = await wallet.writeContract(request);
  log(`sent ${call}: ${hash}`);
  const receipt = await client.waitForTransactionReceipt({ hash, timeout: RECEIPT_TIMEOUT_MS });
  if (receipt.status !== "success") throw new Error(`${hash} reverted in block ${receipt.blockNumber}`);
  log(`confirmed ${hash} in block ${receipt.blockNumber}`);
  return plan;
}

const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);

async function main(argv: readonly string[]): Promise<number> {
  const options = parseCli(argv);
  const deployments = loadDeployments(options.deployments);
  const rpcUrl = process.env.RPC_4663;
  if (!rpcUrl) throw new Error("RPC_4663 is not set; point it at a chain 4663 RPC");
  const account = options.dryRun ? undefined : loadAccount(keyFilePath());
  const transport = http(rpcUrl, { timeout: RPC_TIMEOUT_MS });
  const client = createPublicClient({ chain: robinhood, transport });
  const wallet = account && createWalletClient({ account, chain: robinhood, transport });
  const cadence = options.once ? "once" : `every ${options.intervalMs / 1000} s`;
  const maxMove = `max move ${options.maxMoveBps} bps${options.force ? " (--force)" : ""}`;
  log(
    `keeper: hook ${deployments.hook}, ${deployments.pools.length} pools, threshold ${options.thresholdBps} bps, ` +
      `${maxMove}, ${cadence}, ${account ? `signer ${account.address}` : "dry run"}`,
  );
  const chainId = await client.getChainId();
  if (chainId !== CHAIN_ID) throw new Error(`RPC_4663 serves chain ${chainId}, expected ${CHAIN_ID}`);

  const deps: TickDeps = { client, wallet, fetchPrices: fetchUsdPrices, log };
  for (;;) {
    try {
      await tick(deployments, options, deps);
    } catch (error) {
      console.error(`${new Date().toISOString()} tick failed: ${describeError(error)}`);
      if (options.once) return 1;
    }
    if (options.once) return 0;
    await sleep(options.intervalMs);
  }
}

if (import.meta.main) {
  try {
    process.exitCode = await main(process.argv.slice(2));
  } catch (error) {
    console.error(`keeper: ${describeError(error)}`);
    process.exitCode = 1;
  }
}
