/**
 * Frontend handoff: turns the deploy script's output into the files the web page reads.
 *
 * bun run src/exportForWeb.ts --deployments deployments/4663.json --abi deployments/abi --out out/web/
 *
 * Reads the deployments file and the IndexLpVault and StablePairHook ABIs (forge inspect <Contract> abi --json), checks
 * them, and writes deployments.json and abi/{IndexLpVault,StablePairHook,StateView}.json under --out. Nothing is
 * written unless every check passes. Each flag defaults to the path above, relative to tooling/. The files are then
 * copied into apps/web/src/pages/IndexVault/data/.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { encodeAbiParameters, getAddress, isAddress, keccak256, type Abi, type Address, type Hex } from "viem";
import { CHAIN_ID, CONSTITUENTS, DYNAMIC_FEE_FLAG, INDEX_TOKEN } from "./constituents";

const TOOLING_DIR = join(import.meta.dir, "..");
export const DEFAULT_DEPLOYMENTS = join(TOOLING_DIR, "deployments/4663.json");
export const DEFAULT_ABI_DIR = join(TOOLING_DIR, "deployments/abi");
export const DEFAULT_OUT = join(TOOLING_DIR, "out/web");

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const POOL_ID = /^0x[0-9a-fA-F]{64}$/;
const ZERO_ADDRESS = /^0x0{40}$/;
/** One pool per constituent; any other count is a truncated or stale deployment. */
const EXPECTED_CONSTITUENTS = CONSTITUENTS.length;
const TOTAL_BPS = 10_000;
/** The weights are rounded, so their sum may miss the total by a couple of bps. */
const BPS_TOLERANCE = 2;
const DEPLOYMENTS_HINT = "run the deploy script first, or pass --deployments <file>";
const ABI_HINT = "export it with forge inspect <Contract> abi --json, or pass --abi <dir>";

/** What the page calls on the vault (totalSupply included); the export fails if the deployed ABI lacks one. */
export const VAULT_FUNCTIONS = [
  "nav",
  "totalSupply",
  "allocations",
  "rangeStatus",
  "constituentCount",
  "constituent",
  "previewDeposit",
  "previewRedeem",
  "holdings",
  "deposit",
  "redeem",
] as const;

/** What the page and the keeper call on the hook. */
export const HOOK_FUNCTIONS = ["feeConfig", "feeState", "getFee", "batchUpdateFeeConfig"] as const;

/** One pool of the bundle: its stock / index token pair and the vault's range in it. */
export interface BundleConstituent {
  symbol: string;
  stock: string;
  poolId: string;
  currency0: string;
  currency1: string;
  tickSpacing: number;
  tickLower: number;
  tickUpper: number;
  targetBps: number;
}

/** The deployments.json the page reads. Addresses and pool ids are kept exactly as the deploy script wrote them. */
export interface DeploymentBundle {
  chainId: number;
  hook: string;
  vault: string;
  indexToken: string;
  positionManager: string;
  poolManager: string;
  stateView: string;
  constituents: BundleConstituent[];
}

/** An error as a single line, so a failure never spreads over several lines of output. */
function oneLine(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).replace(/\s+/g, " ").trim();
}

/** A value for an error message: compact JSON, cut short. */
function show(value: unknown): string {
  return (JSON.stringify(value) ?? String(value)).slice(0, 80);
}

function invalid(message: string): never {
  throw new Error(`deployments: ${message}`);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

const sameAddress = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/**
 * The PoolId of an index pool, which every pool here is a dynamic-fee pool of:
 * keccak256(abi.encode(PoolKey(currency0, currency1, DYNAMIC_FEE_FLAG, tickSpacing, hook))), as in v4-core's PoolId.
 */
export function poolIdOf(currency0: string, currency1: string, tickSpacing: number, hook: string): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
      [currency0 as Address, currency1 as Address, DYNAMIC_FEE_FLAG, tickSpacing, hook as Address],
    ),
  );
}

function addressField(value: unknown, field: string): string {
  if (typeof value !== "string" || !ADDRESS.test(value)) {
    invalid(`${field} must be 0x plus 40 hex digits, got ${show(value)}`);
  }
  // All-lowercase passes; mixed case must be the EIP-55 checksum, which viem (so the page) enforces on every address.
  if (!isAddress(value)) invalid(`${field} has a wrong EIP-55 checksum, got ${value}, expected ${getAddress(value)}`);
  return value;
}

function integerField(value: unknown, field: string, min?: number): number {
  if (typeof value !== "number" || !Number.isInteger(value) || (min !== undefined && value < min)) {
    invalid(`${field} must be an integer${min === undefined ? "" : ` >= ${min}`}, got ${show(value)}`);
  }
  return value;
}

function constituentEntry(entry: unknown, i: number, indexToken: string, hook: string): BundleConstituent {
  if (!isRecord(entry)) invalid(`constituents[${i}] must be an object, got ${show(entry)}`);
  const { symbol } = entry;
  if (typeof symbol !== "string" || symbol === "") invalid(`constituents[${i}].symbol must be a non-empty string`);
  const at = `constituents[${i}] (${symbol})`;
  const stock = addressField(entry.stock, `${at}.stock`);
  const poolId = entry.poolId;
  if (typeof poolId !== "string" || !POOL_ID.test(poolId)) {
    invalid(`${at}.poolId must be 0x plus 64 hex digits, got ${show(poolId)}`);
  }
  const currency0 = addressField(entry.currency0, `${at}.currency0`);
  const currency1 = addressField(entry.currency1, `${at}.currency1`);
  if (BigInt(currency0) >= BigInt(currency1)) {
    invalid(`${at}: currency0 ${currency0} must sort below currency1 ${currency1}`);
  }
  const indexIsCurrency0 = sameAddress(currency0, indexToken);
  if (!indexIsCurrency0 && !sameAddress(currency1, indexToken)) {
    invalid(`${at}: neither currency is the index token ${indexToken}`);
  }
  const other = indexIsCurrency0 ? currency1 : currency0;
  if (!sameAddress(stock, other)) invalid(`${at}: stock ${stock} is not the pool's non-index currency ${other}`);
  const tickSpacing = integerField(entry.tickSpacing, `${at}.tickSpacing`, 1);
  const expectedId = poolIdOf(currency0, currency1, tickSpacing, hook);
  if (poolId.toLowerCase() !== expectedId) {
    invalid(`${at}: poolId ${poolId} is not the id of its pool key, expected ${expectedId}`);
  }
  const tickLower = integerField(entry.tickLower, `${at}.tickLower`);
  const tickUpper = integerField(entry.tickUpper, `${at}.tickUpper`);
  if (tickLower % tickSpacing !== 0) {
    invalid(`${at}: tickLower ${tickLower} is not a multiple of tickSpacing ${tickSpacing}`);
  }
  if (tickUpper % tickSpacing !== 0) {
    invalid(`${at}: tickUpper ${tickUpper} is not a multiple of tickSpacing ${tickSpacing}`);
  }
  if (tickLower >= tickUpper) invalid(`${at}: tickLower ${tickLower} must be below tickUpper ${tickUpper}`);
  const targetBps = integerField(entry.targetBps, `${at}.targetBps`, 0);
  // built field by field: the page's file has this key order whatever order the deploy script wrote
  return { symbol, stock, poolId, currency0, currency1, tickSpacing, tickLower, tickUpper, targetBps };
}

/**
 * Checks the deployments file and returns the bundle in the page's key order, dropping unknown keys. Throws naming the
 * first violation.
 */
export function validateDeployments(raw: unknown): DeploymentBundle {
  if (!isRecord(raw)) invalid("not a JSON object");
  if (raw.chainId !== CHAIN_ID) invalid(`chainId is ${show(raw.chainId)}, expected ${CHAIN_ID}`);
  const hook = addressField(raw.hook, "hook");
  if (ZERO_ADDRESS.test(hook)) invalid("hook is the zero address");
  const vault = addressField(raw.vault, "vault");
  if (ZERO_ADDRESS.test(vault)) invalid("vault is the zero address");
  const indexToken = addressField(raw.indexToken, "indexToken");
  if (!sameAddress(indexToken, INDEX_TOKEN)) invalid(`indexToken is ${indexToken}, expected ${INDEX_TOKEN}`);
  // The chain's own contracts rather than deployment outputs: format and checksum are checked, the zero address is not.
  const positionManager = addressField(raw.positionManager, "positionManager");
  const poolManager = addressField(raw.poolManager, "poolManager");
  const stateView = addressField(raw.stateView, "stateView");
  const { constituents } = raw;
  if (!Array.isArray(constituents) || constituents.length !== EXPECTED_CONSTITUENTS) {
    const got = Array.isArray(constituents) ? `${constituents.length} entries` : show(constituents);
    invalid(`constituents must be an array of ${EXPECTED_CONSTITUENTS} entries, got ${got}`);
  }
  const entries = constituents.map((entry: unknown, i) => constituentEntry(entry, i, indexToken, hook));
  // each poolId is its pool key's, so a repeated id is the same pool listed twice
  const firstWithId = new Map<string, number>();
  entries.forEach((c, i) => {
    const id = c.poolId.toLowerCase();
    const first = firstWithId.get(id);
    if (first !== undefined) {
      const original = `constituents[${first}] (${entries[first]!.symbol})`;
      invalid(`constituents[${i}] (${c.symbol}): poolId ${c.poolId} duplicates ${original}`);
    }
    firstWithId.set(id, i);
  });
  const totalBps = entries.reduce((sum, c) => sum + c.targetBps, 0);
  if (Math.abs(totalBps - TOTAL_BPS) > BPS_TOLERANCE) {
    invalid(`targetBps sum to ${totalBps}, expected ${TOTAL_BPS} +/- ${BPS_TOLERANCE}`);
  }
  return { chainId: CHAIN_ID, hook, vault, indexToken, positionManager, poolManager, stateView, constituents: entries };
}

const NAMED_ABI_ITEMS = ["function", "event", "error"];
const NAMELESS_ABI_ITEMS = ["constructor", "fallback", "receive"];

function isAbiItem(item: unknown): item is { type: string; name?: string } {
  if (!isRecord(item) || typeof item.type !== "string") return false;
  if (NAMELESS_ABI_ITEMS.includes(item.type)) return true;
  return NAMED_ABI_ITEMS.includes(item.type) && typeof item.name === "string" && item.name !== "";
}

/**
 * Throws unless `abi` is a JSON array of ABI items that declares a function for every name in `functions`. An event or
 * error of the same name does not count. `label` says which ABI the message is about; `hint`, when given, ends the
 * message about input that is not an array (a forge artifact object, say), saying how to get the array.
 */
export function checkAbiHas(abi: unknown, functions: readonly string[], label: string, hint?: string): void {
  if (!Array.isArray(abi)) {
    const what =
      isRecord(abi) && Array.isArray(abi.abi)
        ? "a forge artifact, not a JSON array of ABI items"
        : "not a JSON array of ABI items";
    throw new Error(`${label} is ${what}${hint === undefined ? "" : `; ${hint}`}`);
  }
  const items: unknown[] = abi;
  const bad = items.findIndex((item) => !isAbiItem(item));
  if (bad !== -1) throw new Error(`${label} item ${bad} is not an ABI item, got ${show(items[bad])}`);
  const declared = new Set(items.filter(isAbiItem).flatMap((item) => (item.type === "function" ? [item.name] : [])));
  const missing = functions.filter((name) => !declared.has(name));
  if (missing.length > 0) throw new Error(`${label} is missing function(s): ${missing.join(", ")}`);
}

/**
 * getSlot0(bytes32 poolId) of the v4 StateView, laid out like the page's abi/StateView.json. Input and outputs are
 * named: the page's ABI test pins every name the JSON gives.
 */
export function buildStateViewAbi(): Abi {
  return [
    {
      name: "getSlot0",
      type: "function",
      stateMutability: "view",
      inputs: [{ type: "bytes32", name: "poolId" }],
      outputs: [
        { type: "uint160", name: "sqrtPriceX96" },
        { type: "int24", name: "tick" },
        { type: "uint24", name: "protocolFee" },
        { type: "uint24", name: "lpFee" },
      ],
    },
  ];
}

/** The one serializer for every file written, so a rerun is byte-identical. */
const serialize = (value: unknown): string => `${JSON.stringify(value, null, 2)}\n`;

/**
 * Reads and parses a JSON input; `kind` says what the file is and `hint` how to produce it. A file that is missing or
 * cannot be read is reported as such, apart from one that is read but is not JSON.
 */
function readJson(path: string, kind: string, hint: string): unknown {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") throw new Error(`no ${kind} at ${path}; ${hint}`);
    throw new Error(`cannot read ${kind} at ${path} (${oneLine(error)}); ${hint}`);
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${kind} at ${path} is not valid JSON (${oneLine(error)}); ${hint}`);
  }
}

export interface ExportOptions {
  deployments: string;
  abiDir: string;
  out: string;
}

const ABIS = [
  { name: "IndexLpVault", functions: VAULT_FUNCTIONS },
  { name: "StablePairHook", functions: HOOK_FUNCTIONS },
];

/** Checks every input, then writes the bundle under `out` and returns the paths. A failed check writes nothing. */
export function exportForWeb({ deployments, abiDir, out }: ExportOptions): string[] {
  const bundle = validateDeployments(readJson(deployments, "deployments file", DEPLOYMENTS_HINT));
  const files: { file: string; content: unknown }[] = [{ file: "deployments.json", content: bundle }];
  for (const { name, functions } of ABIS) {
    const path = join(abiDir, `${name}.json`);
    const abi = readJson(path, `${name} ABI`, ABI_HINT);
    checkAbiHas(abi, functions, `${name} ABI (${path})`, ABI_HINT);
    files.push({ file: `abi/${name}.json`, content: abi });
  }
  files.push({ file: "abi/StateView.json", content: buildStateViewAbi() });
  return files.map(({ file, content }) => {
    const path = join(out, file);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, serialize(content));
    return path;
  });
}

/** The CLI flags, each defaulting to its documented path. */
export function parseCli(args: readonly string[]): ExportOptions {
  const { values } = parseArgs({
    args: [...args],
    options: {
      deployments: { type: "string", default: DEFAULT_DEPLOYMENTS },
      abi: { type: "string", default: DEFAULT_ABI_DIR },
      out: { type: "string", default: DEFAULT_OUT },
    },
  });
  return { deployments: values.deployments, abiDir: values.abi, out: values.out };
}

/** CLI entry: runs the export, prints the files written and returns the exit code. A failure is one stderr line. */
export function main(args: readonly string[]): number {
  try {
    for (const file of exportForWeb(parseCli(args))) console.log(`wrote ${file}`);
    return 0;
  } catch (error) {
    console.error(`exportForWeb: ${oneLine(error)}`);
    return 1;
  }
}

if (import.meta.main) process.exitCode = main(process.argv.slice(2));
