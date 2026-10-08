import { describe, expect, test } from "bun:test";
import { computeReference, tickFromSqrtPriceX96, rangeTicks, orderCurrencies } from "../src/sqrtPrice";
import { getAddress } from "viem";
import { CONSTITUENTS, INDEX_TOKEN } from "../src/constituents";
import { buildPoolConfig, type PoolConfig } from "../src/poolConfig";

const Q96 = 2n ** 96n;
describe("sqrtPrice", () => {
  test("price 1:1 gives 2^96", () => {
    expect(computeReference(100, 100)).toBe(Q96);
  });
  test("referenceForStockAsCurrency1", () => {
    // stock = currency1 at 190 USD, QQQ = currency0 at 610 USD -> price (currency1 per currency0) = 610/190
    const ref = computeReference(610, 190);
    const price = Number(ref * ref) / Number(Q96 * Q96);
    expect(price).toBeCloseTo(610 / 190, 6);
  });
  test("tick of 2^96 is 0 and range rounds to spacing", () => {
    expect(tickFromSqrtPriceX96(Q96)).toBe(0);
    expect(rangeTicks(0, 15, 10)).toEqual({ tickLower: -1400, tickUpper: 1400 }); // ln(1.15)/ln(1.0001) = 1397.7 each side
  });
  test("tick floors toward negative infinity", () => {
    expect(tickFromSqrtPriceX96(computeReference(1, 2))).toBe(-6932); // ln(0.5)/ln(1.0001) = -6931.8
    expect(tickFromSqrtPriceX96(computeReference(2, 1))).toBe(6931);
  });
  test("rangeTicks spans ln(1 + x) / ln(1.0001) ticks each side, rounded outward to spacing", () => {
    // [centerTick, halfWidthPct, tickLower, tickUpper]
    const cases = [
      [0, 15, -1400, 1400],
      [-7884, 15, -9290, -6480],
      [3588, 15, 2190, 4990],
      [0, 25, -2240, 2240],
      [-3348, 25, -5580, -1110],
      [0, 30, -2630, 2630],
      [-7009, 30, -9640, -4380],
    ] as const;
    for (const [center, pct, tickLower, tickUpper] of cases) {
      expect({ center, pct, ...rangeTicks(center, pct, 10) }).toEqual({ center, pct, tickLower, tickUpper });
    }
  });
  test("orderCurrencies sorts by address", () => {
    const [c0, c1, stockIs0] = orderCurrencies(
      "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC",
      "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68",
    );
    expect(c0.toLowerCase() < c1.toLowerCase()).toBe(true);
    expect(stockIs0).toBe(true);
  });
});

// approximate USD prices from the plan; only consistency matters here
const USD: Record<string, number> = {
  QQQ: 610,
  NVDA: 190,
  AAPL: 258,
  MSFT: 520,
  GOOGL: 250,
  MU: 190,
  AMD: 230,
  AMZN: 220,
  META: 710,
  TSLA: 440,
  AVGO: 350,
};
const PRICES: Record<string, number> = Object.fromEntries([
  [INDEX_TOKEN.toLowerCase(), USD.QQQ!],
  ...CONSTITUENTS.map((c) => [c.address.toLowerCase(), USD[c.symbol]!]),
]);
const HOOK = "0x0000000000000000000000000000000000000000";
const pool = (config: PoolConfig, symbol: string) => config.pools.find((p) => p.symbol === symbol)!;

describe("buildPoolConfig", () => {
  const config = buildPoolConfig(HOOK, PRICES);

  test("serializes to the A3 schema: field names in order, bigints as decimal strings", () => {
    const json = JSON.parse(JSON.stringify(config));
    expect(Object.keys(json)).toEqual(["chainId", "hook", "indexToken", "pools"]);
    expect([json.chainId, json.hook, json.indexToken]).toEqual([
      4663,
      HOOK,
      "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68",
    ]);
    for (const p of json.pools) {
      expect(Object.keys(p)).toEqual([
        "symbol",
        "stock",
        "currency0",
        "currency1",
        "stockIsCurrency0",
        "fee",
        "tickSpacing",
        "sqrtPriceX96",
        "currentTick",
        "tickLower",
        "tickUpper",
        "targetBps",
        "tier",
        "feeConfig",
      ]);
      expect(Object.keys(p.feeConfig)).toEqual(["k", "optimalFeeE6", "targetMultiplier", "referenceSqrtPriceX96"]);
      expect(p.sqrtPriceX96).toMatch(/^[1-9][0-9]*$/);
      expect(p.feeConfig.referenceSqrtPriceX96).toBe(p.sqrtPriceX96);
    }
  });

  test("one pool per constituent with the plan's weights and tiers", () => {
    expect(config.pools.map((p) => `${p.symbol} ${p.targetBps} ${p.tier}`)).toEqual([
      "NVDA 1719 high",
      "AAPL 1484 low",
      "MSFT 1172 low",
      "GOOGL 1172 low",
      "MU 1016 high",
      "AMD 859 high",
      "AMZN 840 low",
      "META 645 low",
      "TSLA 566 tsla",
      "AVGO 527 high",
    ]);
    expect(config.pools.reduce((sum, p) => sum + p.targetBps, 0)).toBe(10000);
  });

  test("currencies are sorted, checksummed and consistent with stockIsCurrency0", () => {
    for (const p of config.pools) {
      expect(p.currency0.toLowerCase() < p.currency1.toLowerCase()).toBe(true);
      expect([p.stock, p.currency0, p.currency1].map((a) => getAddress(a))).toEqual([
        p.stock,
        p.currency0,
        p.currency1,
      ]);
      expect(p.stockIsCurrency0 ? [p.currency0, p.currency1] : [p.currency1, p.currency0]).toEqual([
        p.stock,
        INDEX_TOKEN,
      ]);
    }
    expect([pool(config, "NVDA").stockIsCurrency0, pool(config, "MSFT").stockIsCurrency0]).toEqual([true, false]);
  });

  test("reference is sqrt(usd(currency0) / usd(currency1)) in both orientations", () => {
    expect(pool(config, "NVDA").sqrtPriceX96).toBe(computeReference(USD.NVDA!, USD.QQQ!).toString());
    expect(pool(config, "MSFT").sqrtPriceX96).toBe(computeReference(USD.QQQ!, USD.MSFT!).toString());
  });

  test("current tick comes from the sqrt price and the tier's range brackets it on spacing", () => {
    const halfWidthPct = { low: 15, high: 25, tsla: 30 };
    for (const p of config.pools) {
      expect(p.currentTick).toBe(tickFromSqrtPriceX96(BigInt(p.sqrtPriceX96)));
      expect({ tickLower: p.tickLower, tickUpper: p.tickUpper }).toEqual(
        rangeTicks(p.currentTick, halfWidthPct[p.tier], 10),
      );
      expect([Math.abs(p.tickLower % 10), Math.abs(p.tickUpper % 10)]).toEqual([0, 0]);
      expect(p.tickLower).toBeLessThan(p.currentTick);
      expect(p.currentTick).toBeLessThan(p.tickUpper);
    }
  });

  test("band is ±x% in log terms of the stock price in QQQ, whichever currency the stock is", () => {
    const halfWidthPct = { low: 15, high: 25, tsla: 30 };
    expect(config.pools.filter((p) => !p.stockIsCurrency0).map((p) => p.symbol)).toEqual(["MSFT", "MU"]);
    const bands = config.pools.map((p) => {
      const toStockInQqq = (poolPrice: number) => (p.stockIsCurrency0 ? poolPrice : 1 / poolPrice);
      const center = toStockInQqq((Number(BigInt(p.sqrtPriceX96)) / 2 ** 96) ** 2);
      const [lower, upper] = [1.0001 ** p.tickLower, 1.0001 ** p.tickUpper].map(toStockInQqq).sort((a, b) => a - b);
      return {
        symbol: p.symbol,
        x: halfWidthPct[p.tier],
        up: (upper! / center - 1) * 100,
        down: (center / lower! - 1) * 100,
      };
    });
    expect(bands.filter((b) => Math.abs(b.up - b.x) > 0.2 || Math.abs(b.down - b.x) > 0.2)).toEqual([]);
  });

  test("dynamic fee key and per-tier fee config", () => {
    for (const p of config.pools) {
      expect([p.fee, p.tickSpacing]).toEqual([8388608, 10]);
      expect(p.feeConfig).toEqual({
        k: 16757000,
        optimalFeeE6: p.tier === "low" ? 3000 : 5000,
        targetMultiplier: 100,
        referenceSqrtPriceX96: p.sqrtPriceX96,
      });
    }
  });

  test("throws when a constituent has no price", () => {
    expect(() => buildPoolConfig(HOOK, { [INDEX_TOKEN.toLowerCase()]: 610 })).toThrow("no valid USD price");
  });

  test("rejects non-finite or non-positive prices", () => {
    const nvda = CONSTITUENTS.find((c) => c.symbol === "NVDA")!.address;
    for (const bad of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(() => buildPoolConfig(HOOK, { ...PRICES, [nvda.toLowerCase()]: bad })).toThrow(
        `no valid USD price for ${nvda}`,
      );
    }
  });
});
