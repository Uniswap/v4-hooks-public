import type { Address } from "viem";

export type Tier = "low" | "high" | "tsla";

export interface Constituent {
  symbol: string;
  address: Address;
  targetBps: number;
  tier: Tier;
}

export const CHAIN_ID = 4663;
/** QQQ: every pool is stock / QQQ. */
export const INDEX_TOKEN: Address = "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68";
/** LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000). */
export const DYNAMIC_FEE_FLAG = 8388608;
export const TICK_SPACING = 10;
/** StablePairHook fee config shared by every pool: k in Q24 (about 0.9988 per block). */
export const K = 16757000;
export const TARGET_MULTIPLIER = 100;

export const TIERS: Record<Tier, { halfWidthPct: number; optimalFeeE6: number }> = {
  low: { halfWidthPct: 15, optimalFeeE6: 3000 },
  high: { halfWidthPct: 25, optimalFeeE6: 5000 },
  tsla: { halfWidthPct: 30, optimalFeeE6: 5000 },
};

/** All 18 decimals; targetBps sums to 10000. */
export const CONSTITUENTS: readonly Constituent[] = [
  { symbol: "NVDA", address: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", targetBps: 1719, tier: "high" },
  { symbol: "AAPL", address: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", targetBps: 1484, tier: "low" },
  { symbol: "MSFT", address: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", targetBps: 1172, tier: "low" },
  { symbol: "GOOGL", address: "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", targetBps: 1172, tier: "low" },
  { symbol: "MU", address: "0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD", targetBps: 1016, tier: "high" },
  { symbol: "AMD", address: "0x86923f96303D656E4aa86D9d42D1e57ad2023fdC", targetBps: 859, tier: "high" },
  { symbol: "AMZN", address: "0x12f190a9F9d7D37a250758b26824B97CE941bF54", targetBps: 840, tier: "low" },
  { symbol: "META", address: "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35", targetBps: 645, tier: "low" },
  { symbol: "TSLA", address: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", targetBps: 566, tier: "tsla" },
  { symbol: "AVGO", address: "0x156E175DD063a8cE274C50654eF40e0032b3fbcF", targetBps: 527, tier: "high" },
];
