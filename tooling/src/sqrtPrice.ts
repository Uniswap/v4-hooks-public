import type { Address } from "viem";

const LOG_TICK_BASE = Math.log(1.0001);

/** sqrtPriceX96 of the pool price (currency1 per currency0) = usdCurrency0 / usdCurrency1; every token here has 18 decimals. */
export function computeReference(usdCurrency0: number, usdCurrency1: number): bigint {
  // scale by 2^48 as a float and by 2^48 again as a bigint so the rounding stays inside the float's 53-bit mantissa
  return BigInt(Math.round(Math.sqrt(usdCurrency0 / usdCurrency1) * 2 ** 48)) * 2n ** 48n;
}

export function tickFromSqrtPriceX96(sqrtPriceX96: bigint): number {
  return Math.floor((Math.log(Number(sqrtPriceX96) / 2 ** 96) * 2) / LOG_TICK_BASE);
}

/** Ticks covering price × (1 ∓ halfWidthPct%) around centerTick, rounded outward to multiples of spacing. */
export function rangeTicks(
  centerTick: number,
  halfWidthPct: number,
  spacing: number,
): { tickLower: number; tickUpper: number } {
  const lower = centerTick + Math.log(1 - halfWidthPct / 100) / LOG_TICK_BASE;
  const upper = centerTick + Math.log(1 + halfWidthPct / 100) / LOG_TICK_BASE;
  return { tickLower: Math.floor(lower / spacing) * spacing, tickUpper: Math.ceil(upper / spacing) * spacing };
}

/** v4 currency order for a stock / index pair: [currency0, currency1, stockIsCurrency0]. */
export function orderCurrencies(stock: Address, index: Address): [Address, Address, boolean] {
  const stockIsCurrency0 = stock.toLowerCase() < index.toLowerCase();
  return stockIsCurrency0 ? [stock, index, true] : [index, stock, false];
}
