import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { getAddress, type Address } from "viem";
import {
  CHAIN_ID,
  CONSTITUENTS,
  DYNAMIC_FEE_FLAG,
  INDEX_TOKEN,
  K,
  TARGET_MULTIPLIER,
  TICK_SPACING,
  TIERS,
  type Tier,
} from "./constituents";
import { fetchUsdPrices } from "./prices";
import { computeReference, orderCurrencies, rangeTicks, tickFromSqrtPriceX96 } from "./sqrtPrice";

/** One pool of out/pools.4663.json, the schema script/index-vault/PoolConfigLib.sol reads; bigints are decimal strings. */
export interface PoolEntry {
  symbol: string;
  stock: Address;
  currency0: Address;
  currency1: Address;
  stockIsCurrency0: boolean;
  fee: number;
  tickSpacing: number;
  sqrtPriceX96: string;
  currentTick: number;
  tickLower: number;
  tickUpper: number;
  targetBps: number;
  tier: Tier;
  feeConfig: { k: number; optimalFeeE6: number; targetMultiplier: number; referenceSqrtPriceX96: string };
}

export interface PoolConfig {
  chainId: number;
  hook: Address;
  indexToken: Address;
  pools: PoolEntry[];
}

function usd(prices: Record<string, number>, address: Address): number {
  const price = prices[address.toLowerCase()];
  if (price === undefined) throw new Error(`no USD price for ${address}`);
  return price;
}

/** Every pool starts at its reference, sqrt(usd(currency0) / usd(currency1)), with its tier's range around that tick. */
export function buildPoolConfig(hook: string, prices: Record<string, number>): PoolConfig {
  const pools = CONSTITUENTS.map((c): PoolEntry => {
    const [currency0, currency1, stockIsCurrency0] = orderCurrencies(c.address, INDEX_TOKEN);
    const sqrtPriceX96 = computeReference(usd(prices, currency0), usd(prices, currency1));
    const currentTick = tickFromSqrtPriceX96(sqrtPriceX96);
    const { halfWidthPct, optimalFeeE6 } = TIERS[c.tier];
    const { tickLower, tickUpper } = rangeTicks(currentTick, halfWidthPct, TICK_SPACING);
    return {
      symbol: c.symbol,
      stock: c.address,
      currency0,
      currency1,
      stockIsCurrency0,
      fee: DYNAMIC_FEE_FLAG,
      tickSpacing: TICK_SPACING,
      sqrtPriceX96: sqrtPriceX96.toString(),
      currentTick,
      tickLower,
      tickUpper,
      targetBps: c.targetBps,
      tier: c.tier,
      feeConfig: {
        k: K,
        optimalFeeE6,
        targetMultiplier: TARGET_MULTIPLIER,
        referenceSqrtPriceX96: sqrtPriceX96.toString(),
      },
    };
  });
  return { chainId: CHAIN_ID, hook: getAddress(hook), indexToken: INDEX_TOKEN, pools };
}

function formatTable(config: PoolConfig, prices: Record<string, number>): string {
  const header = [
    "symbol",
    "stockUsd",
    "qqqUsd",
    "c0/c1",
    "price c1/c0",
    "tick",
    "tickLower",
    "tickUpper",
    "tier",
    "bps",
  ];
  const rows = config.pools.map((p) =>
    [
      p.symbol,
      usd(prices, p.stock).toFixed(2),
      usd(prices, config.indexToken).toFixed(2),
      p.stockIsCurrency0 ? `${p.symbol}/QQQ` : `QQQ/${p.symbol}`,
      (usd(prices, p.currency0) / usd(prices, p.currency1)).toFixed(6),
      p.currentTick,
      p.tickLower,
      p.tickUpper,
      `${p.tier} ±${TIERS[p.tier].halfWidthPct}%`,
      p.targetBps,
    ].map(String),
  );
  const widths = header.map((h, i) => Math.max(h.length, ...rows.map((row) => row[i]!.length)));
  return [header, ...rows]
    .map((row) => row.map((cell, i) => (i === 0 ? cell.padEnd(widths[i]!) : cell.padStart(widths[i]!))).join("  "))
    .join("\n");
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      hook: { type: "string" },
      out: { type: "string", default: join(import.meta.dir, "../out/pools.4663.json") },
    },
  });
  if (values.hook === undefined) {
    throw new Error("usage: bun run src/poolConfig.ts --hook <address> [--out out/pools.4663.json]");
  }
  const prices = await fetchUsdPrices([INDEX_TOKEN, ...CONSTITUENTS.map((c) => c.address)]);
  const config = buildPoolConfig(values.hook, prices);
  mkdirSync(dirname(values.out), { recursive: true });
  writeFileSync(values.out, `${JSON.stringify(config, null, 2)}\n`);
  console.log(formatTable(config, prices));
  console.log(`\nwrote ${config.pools.length} pools to ${values.out} (hook ${config.hook})`);
}

if (import.meta.main) await main();
