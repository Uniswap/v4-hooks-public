import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  custom,
  decodeFunctionData,
  encodeErrorResult,
  encodeFunctionData,
  encodeFunctionResult,
  getAbiItem,
  getAddress,
  keccak256,
  parseTransaction,
  toFunctionSelector,
  type Address,
  type Hex,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { robinhood } from "viem/chains";
import {
  alignPass,
  checkSwapper,
  deviationBps,
  formatAlignment,
  loadAlignDeployments,
  parseAlignDeployments,
  parseCli,
  planAlignments,
  poolSwapTestAbi,
  SKIP_REASON,
  stateViewAbi,
  type AlignPool,
  type PoolKey,
  type PoolReading,
  type SwapArgs,
} from "../src/alignPools";
import { CONSTITUENTS, INDEX_TOKEN } from "../src/constituents";
import { poolIdOf } from "../src/exportForWeb";
import { stablePairHookAbi } from "../src/hookAbi";
import { DEFAULT_DEPLOYMENTS } from "../src/keeper";
import { computeReference } from "../src/sqrtPrice";

const stock = (symbol: string) => CONSTITUENTS.find((c) => c.symbol === symbol)!.address;
const NVDA = stock("NVDA"); // sorts below QQQ, so it is currency0 and the pool price is QQQ per NVDA
const MSFT = stock("MSFT"); // sorts above QQQ, so QQQ is currency0 and the pool price is MSFT per QQQ
const HOOK = getAddress("0xabcdefabcdefabcdefabcdefabcdefabcdefabcd");
const POOL_MANAGER = getAddress("0x3333333333333333333333333333333333333333");
const STATE_VIEW = getAddress("0x4444444444444444444444444444444444444444");
const SWAPPER = getAddress("0x5555555555555555555555555555555555555555");
const NVDA_ID = poolIdOf(NVDA, INDEX_TOKEN, 10, HOOK);
const MSFT_ID = poolIdOf(INDEX_TOKEN, MSFT, 10, HOOK);
const sameAddress = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

const DEPLOYMENTS = {
  chainId: 4663,
  hook: HOOK,
  vault: "0x1111111111111111111111111111111111111111",
  indexToken: INDEX_TOKEN,
  positionManager: "0x2222222222222222222222222222222222222222",
  poolManager: POOL_MANAGER,
  stateView: STATE_VIEW,
  constituents: [
    {
      symbol: "NVDA",
      stock: NVDA,
      poolId: NVDA_ID,
      currency0: NVDA,
      currency1: INDEX_TOKEN,
      tickSpacing: 10,
      tickLower: -14000,
      tickUpper: -9520,
      targetBps: 1719,
    },
    {
      symbol: "MSFT",
      stock: MSFT,
      poolId: MSFT_ID,
      currency0: INDEX_TOKEN,
      currency1: MSFT,
      tickSpacing: 10,
      tickLower: 2170,
      tickUpper: 4980,
      targetBps: 1172,
    },
  ],
};
const deployments = parseAlignDeployments(DEPLOYMENTS);
const [nvda, msft] = deployments.pools as [AlignPool, AlignPool];
const reading = (pool: AlignPool, spot: bigint, reference: bigint, liquidity = 0n): PoolReading => ({
  poolId: pool.poolId,
  sqrtPriceX96: spot,
  liquidity,
  referenceSqrtPriceX96: reference,
});
// sqrt prices a whole number of 2^90 apart, so their ratios (and the deviations) are exact decimals
const at = (n: bigint) => n * 2n ** 90n;

describe("deviationBps", () => {
  test("is (spot / reference)^2 - 1 in bps, exact on either side", () => {
    expect(deviationBps(at(101n), at(100n))).toBe(201); // 1.01^2 - 1
    expect(deviationBps(at(99n), at(100n))).toBe(-199); // 0.99^2 - 1
    expect(deviationBps(at(1001n), at(1000n))).toBe(20.01);
    expect(deviationBps(at(999n), at(1000n))).toBe(-19.99);
    expect(deviationBps(at(100n), at(100n))).toBe(0);
    expect(() => deviationBps(at(100n), 0n)).toThrow("the reference must be positive, got 0");
  });

  test("hand-checked where QQQ is currency0 (MSFT, MU) and where the stock is (NVDA)", () => {
    // Each pool was set at its USD ratio (spot) and the keeper then moved its reference: price = usd(c0) / usd(c1).
    // Expected values: python3 fractions.Fraction((spot^2 - ref^2) x 10^4, ref^2), truncated toward zero to 1e-6.
    const cases: [string, bigint, bigint, number, number][] = [
      // MSFT $520 -> $525.20 (+1%) with QQQ at $610: MSFT per QQQ falls 1%, the stale pool sits above (+100.00000000004)
      ["MSFT", 85810973596552588803090415616n, 85385110056697099260719529984n, 100, 100],
      // MU $100 -> $98 (-2%): MU per QQQ rises, the stale pool sits below (-200.000000000002, truncated toward zero)
      ["MU", 195679126597240149816377344000n, 197665767647956337588097253376n, -200, -200],
      // NVDA $190 -> $191.90 (+1%), NVDA as currency0: QQQ per NVDA rises 1%, the pool sits 190 / 191.9 - 1 below
      ["NVDA", 44217223291521065734927024128n, 44437759439111640189572743168n, -99.0099, -99.00990099],
    ];
    expect([
      [computeReference(610, 520), computeReference(610, 525.2)],
      [computeReference(610, 100), computeReference(610, 98)],
      [computeReference(190, 610), computeReference(191.9, 610)],
    ]).toEqual(cases.map(([, spot, ref]) => [spot, ref]));
    for (const [symbol, spot, ref, expected, intuition] of cases) {
      expect([symbol, deviationBps(spot, ref)]).toEqual([symbol, expected]);
      expect(deviationBps(spot, ref)).toBeCloseTo(intuition, 4);
    }
  });
});

describe("planAlignments", () => {
  const key = (pool: AlignPool): PoolKey => pool.key;
  const settings = { takeClaims: false, settleUsingBurn: false };

  test("an empty pool off band gets the 1 wei exact-input swap limited at its reference, either direction", () => {
    // MSFT (QQQ is currency0) 201 bps above its reference, NVDA 199 bps below
    const plan = planAlignments(
      [nvda, msft],
      [reading(nvda, at(99n), at(100n)), reading(msft, at(101n), at(100n))],
      25,
    );
    expect(plan.map((a) => [a.symbol, a.action, a.deviationBps])).toEqual([
      ["NVDA", "swap", -199],
      ["MSFT", "swap", 201],
    ]);
    expect(plan.map((a) => a.swap)).toEqual([
      [key(nvda), { zeroForOne: false, amountSpecified: -1n, sqrtPriceLimitX96: at(100n) }, settings, "0x"],
      [key(msft), { zeroForOne: true, amountSpecified: -1n, sqrtPriceLimitX96: at(100n) }, settings, "0x"],
    ]);
    expect(key(msft)).toEqual({ currency0: INDEX_TOKEN, currency1: MSFT, fee: 8388608, tickSpacing: 10, hooks: HOOK });
  });

  test("an empty pool within min-bps is left alone", () => {
    const [a] = planAlignments([msft], [reading(msft, at(1001n), at(1000n))], 25); // +20.01 bps
    expect(a).toEqual({
      symbol: "MSFT",
      poolId: MSFT_ID,
      spot: at(1001n),
      reference: at(1000n),
      liquidity: 0n,
      deviationBps: 20.01,
      action: "none",
    });
  });

  test("a pool with liquidity is never swapped: skipped with the reason off band, left alone within it", () => {
    const plan = planAlignments(
      [nvda, msft],
      [reading(nvda, at(101n), at(100n), 1n), reading(msft, at(1001n), at(1000n), 10n ** 18n)],
      25,
    );
    expect(plan.map((a) => [a.symbol, a.action, a.reason, a.swap])).toEqual([
      ["NVDA", "skip", "pool has liquidity (needs an arbitrage, not a free reprice)", undefined],
      ["MSFT", "none", undefined, undefined],
    ]);
    expect(SKIP_REASON).toBe("pool has liquidity (needs an arbitrage, not a free reprice)");
  });

  test("a deviation of exactly min-bps is left alone and one wei of sqrt price more is a swap, either side", () => {
    // (201 / 200)^2 - 1 = +100.25 bps and (199 / 200)^2 - 1 = -99.75 bps, exactly
    const cases: [bigint, number, number][] = [
      [at(201n), 100.25, 100.25],
      [at(199n), 99.75, -99.75],
    ];
    for (const [spot, minBps, deviation] of cases) {
      const [exact] = planAlignments([msft], [reading(msft, spot, at(200n))], minBps);
      expect([exact!.deviationBps, exact!.action]).toEqual([deviation, "none"]);
      const further = deviation > 0 ? spot + 1n : spot - 1n;
      expect(planAlignments([msft], [reading(msft, further, at(200n))], minBps)[0]!.action).toBe("swap");
    }
    // min-bps 0 still leaves a pool exactly on its reference alone
    expect(planAlignments([msft], [reading(msft, at(200n), at(200n))], 0)[0]!.action).toBe("none");
    expect(planAlignments([msft], [reading(msft, at(200n) + 1n, at(200n))], 0)[0]!.action).toBe("swap");
  });

  test("matches readings by poolId in any order or case; throws on a missing reading, a bad pool or bad min-bps", () => {
    const upper = (id: Hex) => id.toUpperCase().replace("0X", "0x") as Hex;
    const plan = planAlignments(
      [nvda, msft],
      [{ ...reading(msft, at(101n), at(100n)), poolId: upper(MSFT_ID) }, reading(nvda, at(100n), at(100n))],
      25,
    );
    expect(plan.map((a) => [a.symbol, a.action])).toEqual([
      ["NVDA", "none"],
      ["MSFT", "swap"],
    ]);
    expect(() => planAlignments([nvda, msft], [reading(nvda, at(1n), at(1n))], 25)).toThrow(
      `no reading for pool MSFT ${MSFT_ID}`,
    );
    expect(() => planAlignments([msft], [reading(msft, 0n, at(1n))], 25)).toThrow(
      `pool MSFT ${MSFT_ID} is not initialized (its slot0 price is 0)`,
    );
    expect(() => planAlignments([msft], [reading(msft, at(1n), 0n)], 25)).toThrow(
      `pool MSFT ${MSFT_ID} has no reference on the hook (its feeConfig is empty)`,
    );
    for (const bad of [-1, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(() => planAlignments([msft], [reading(msft, at(1n), at(1n))], bad)).toThrow(
        "minBps must be a non-negative number",
      );
    }
  });
});

describe("formatAlignment", () => {
  test("names the pool, its liquidity, both prices, the deviation and the decision; a skip is a WARN", () => {
    const [swap] = planAlignments([msft], [reading(msft, at(101n), at(100n))], 25);
    const [skip] = planAlignments([nvda], [reading(nvda, at(99n), at(100n), 7n)], 25);
    const [keep] = planAlignments([nvda], [reading(nvda, at(999n), at(1000n))], 25);
    expect(formatAlignment(swap!, 25)).toStartWith(`MSFT ${MSFT_ID} liquidity 0, spot ${at(101n)} (tick `);
    expect(formatAlignment(swap!, 25)).toEndWith(
      "price +201.00 bps off, beyond 25 bps and empty: swap zeroForOne onto the reference",
    );
    expect(formatAlignment(skip!, 25)).toStartWith(`WARN NVDA ${NVDA_ID} liquidity 7, spot ${at(99n)} (tick `);
    expect(formatAlignment(skip!, 25)).toEndWith(
      "price -199.00 bps off, beyond 25 bps: skipped: pool has liquidity (needs an arbitrage, not a free reprice)",
    );
    expect(formatAlignment(keep!, 25)).toEndWith("price -19.99 bps off, within 25 bps: keep");
  });
});

describe("swap calldata", () => {
  test("a planned swap encodes byte for byte like cast calldata", () => {
    // the live MSFT pool (QQQ is currency0) about 31 bps above its live reference: zeroForOne
    const liveHook = getAddress("0xD5711B1F57e75B1c91c32AD96C4d4E5019D6Bcc0");
    const key = { currency0: INDEX_TOKEN, currency1: MSFT, fee: 8388608, tickSpacing: 10, hooks: liveHook };
    const pool: AlignPool = { symbol: "MSFT", poolId: poolIdOf(INDEX_TOKEN, MSFT, 10, liveHook), key };
    expect(pool.poolId).toBe("0x3340fa91eae89286403650775fa7c0e7ee794f691c495fbe1df1e470de524c5f"); // deployments/4663.json
    const reference = 94852173359227781562457128960n;
    const [a] = planAlignments([pool], [reading(pool, 95_000_000_000_000_000_000_000_000_000n, reference)], 25);
    expect(toFunctionSelector(getAbiItem({ abi: poolSwapTestAbi, name: "swap" }))).toBe(
      "0x2229d0b4", // cast sig "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)"
    );
    // cast calldata "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)"
    //   "(0xD5f3879160bc7c32ebb4dC785F8a4F505888de68,0xe93237C50D904957Cf27E7B1133b510C669c2e74,8388608,10,
    //   0xD5711B1F57e75B1c91c32AD96C4d4E5019D6Bcc0)" "(true,-1,94852173359227781562457128960)" "(false,false)" 0x
    const golden = [
      "0x2229d0b4",
      "000000000000000000000000d5f3879160bc7c32ebb4dc785f8a4f505888de68", // key.currency0 QQQ
      "000000000000000000000000e93237c50d904957cf27e7b1133b510c669c2e74", // key.currency1 MSFT
      "0000000000000000000000000000000000000000000000000000000000800000", // key.fee DYNAMIC_FEE_FLAG
      "000000000000000000000000000000000000000000000000000000000000000a", // key.tickSpacing 10
      "000000000000000000000000d5711b1f57e75b1c91c32ad96c4d4e5019d6bcc0", // key.hooks
      "0000000000000000000000000000000000000000000000000000000000000001", // params.zeroForOne true
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", // params.amountSpecified -1
      "0000000000000000000000000000000000000001327be0fd0d65000000000000", // params.sqrtPriceLimitX96 = reference
      "0000000000000000000000000000000000000000000000000000000000000000", // testSettings.takeClaims false
      "0000000000000000000000000000000000000000000000000000000000000000", // testSettings.settleUsingBurn false
      "0000000000000000000000000000000000000000000000000000000000000160", // offset of hookData
      "0000000000000000000000000000000000000000000000000000000000000000", // hookData.length 0
    ].join("") as Hex;
    expect(encodeFunctionData({ abi: poolSwapTestAbi, functionName: "swap", args: a!.swap! })).toBe(golden);
    expect(decodeFunctionData({ abi: poolSwapTestAbi, data: golden }).args).toEqual(a!.swap!);
  });
});

describe("deployments", () => {
  test("parseAlignDeployments keeps each pool's symbol and poolId and builds its dynamic-fee key on the hook", () => {
    expect(deployments).toEqual({
      hook: HOOK,
      stateView: STATE_VIEW,
      poolManager: POOL_MANAGER,
      pools: [
        {
          symbol: "NVDA",
          poolId: NVDA_ID,
          key: { currency0: NVDA, currency1: INDEX_TOKEN, fee: 8388608, tickSpacing: 10, hooks: HOOK },
        },
        {
          symbol: "MSFT",
          poolId: MSFT_ID,
          key: { currency0: INDEX_TOKEN, currency1: MSFT, fee: 8388608, tickSpacing: 10, hooks: HOOK },
        },
      ],
    });
  });

  test("the committed 4663 file parses: ten pools on its hook, each key hashing to its poolId", () => {
    const live = loadAlignDeployments(DEFAULT_DEPLOYMENTS);
    expect(live.pools.map((p) => p.symbol)).toEqual(CONSTITUENTS.map((c) => c.symbol));
    for (const { poolId, key } of live.pools) {
      expect(key.hooks).toBe(live.hook);
      expect(poolIdOf(key.currency0, key.currency1, key.tickSpacing, key.hooks)).toBe(poolId.toLowerCase() as Hex);
    }
  });

  test("rejects a key that does not hash to its poolId and a bad tickSpacing, stateView or poolManager", () => {
    const withPool = (i: number, patch: Record<string, unknown>) => ({
      ...DEPLOYMENTS,
      constituents: DEPLOYMENTS.constituents.map((c, j) => (j === i ? { ...c, ...patch } : c)),
    });
    const spacing = "must be an integer from 1 to 32767";
    const otherHook = getAddress("0x9999999999999999999999999999999999999999");
    const cases: [unknown, string][] = [
      [
        withPool(1, { tickSpacing: 60 }),
        `deployments: constituents[1] (MSFT): poolId ${MSFT_ID} is not the id of its pool key, expected ` +
          poolIdOf(INDEX_TOKEN, MSFT, 60, HOOK),
      ],
      [
        { ...DEPLOYMENTS, hook: otherHook }, // every poolId depends on the hook
        `deployments: constituents[0] (NVDA): poolId ${NVDA_ID} is not the id of its pool key, expected ` +
          poolIdOf(NVDA, INDEX_TOKEN, 10, otherHook),
      ],
      [withPool(0, { tickSpacing: 0 }), `deployments: constituents[0] (NVDA).tickSpacing ${spacing}`],
      [withPool(0, { tickSpacing: 32768 }), `deployments: constituents[0] (NVDA).tickSpacing ${spacing}`],
      [withPool(1, { tickSpacing: "10" }), `deployments: constituents[1] (MSFT).tickSpacing ${spacing}`],
      [withPool(1, { tickSpacing: 10.5 }), `deployments: constituents[1] (MSFT).tickSpacing ${spacing}`],
      [{ ...DEPLOYMENTS, stateView: "0x1234" }, "deployments: stateView is not an address"],
      [{ ...DEPLOYMENTS, poolManager: undefined }, "deployments: poolManager is not an address"],
      [{ ...DEPLOYMENTS, chainId: 1 }, "deployments: chainId is 1, expected 4663"], // the keeper's checks still apply
    ];
    for (const [raw, message] of cases) expect(() => parseAlignDeployments(raw)).toThrow(message);
  });

  test("loadAlignDeployments reads a file and names a missing one or one that is not JSON", () => {
    const dir = mkdtempSync(join(tmpdir(), "align-deployments-"));
    const path = join(dir, "4663.json");
    writeFileSync(path, JSON.stringify(DEPLOYMENTS));
    expect(loadAlignDeployments(path)).toEqual(deployments);
    const missing = join(dir, "missing.json");
    expect(() => loadAlignDeployments(missing)).toThrow(
      `no deployments file at ${missing}; deploy first or pass --deployments <file>`,
    );
    const garbled = join(dir, "garbled.json");
    writeFileSync(garbled, "{");
    expect(() => loadAlignDeployments(garbled)).toThrow(`${garbled} is not valid JSON`);
  });
});

interface FakePool {
  spot: bigint;
  liquidity: bigint;
  reference: bigint;
}

interface FakeBehaviour {
  /** false: a sent swap leaves the price where it was (on chain an empty pool's price moves onto the limit). */
  swapMoves?: boolean;
  /** The hook's reference once a swap is sent, as if the keeper moved it in the same block. */
  referenceAfterSwap?: bigint;
  /** The pool whose swap simulation reverts PriceLimitAlreadyExceeded. */
  revertSwapOf?: Hex;
  /** feeConfig returns no data, like a hook address without code. */
  silentHook?: boolean;
  swapperCode?: Hex;
  swapperManager?: Address;
}

/**
 * A chain 4663 node on viem's custom transport that records every method and the block of every eth_call. StateView
 * and the hook answer from its pool state; the swapper (SWAPPER) simulates swaps, and a sent swap moves an empty
 * pool's price onto its limit as v4 does. Every receipt is a success in block 2.
 */
function fakeNode(initial: Record<Hex, FakePool>, behaviour: FakeBehaviour = {}) {
  const state = new Map(Object.entries(initial).map(([poolId, pool]) => [poolId.toLowerCase(), { ...pool }]));
  const methods: string[] = [];
  const callBlocks: unknown[] = [];
  const sent: SwapArgs[] = [];
  const poolOf = (poolId: Hex) => state.get(poolId.toLowerCase()) ?? { spot: 0n, liquidity: 0n, reference: 0n };
  const idOf = (key: PoolKey) => poolIdOf(key.currency0, key.currency1, key.tickSpacing, key.hooks);
  const request = async ({ method, params }: { method: string; params?: unknown }) => {
    methods.push(method);
    switch (method) {
      case "eth_call": {
        const [{ to, data }, block] = params as [{ to: Address; data: Hex }, unknown];
        callBlocks.push(block);
        if (sameAddress(to, STATE_VIEW)) {
          const call = decodeFunctionData({ abi: stateViewAbi, data });
          const { spot, liquidity } = poolOf(call.args[0]);
          return call.functionName === "getSlot0"
            ? encodeFunctionResult({ abi: stateViewAbi, functionName: "getSlot0", result: [spot, 0, 0, 0] })
            : encodeFunctionResult({ abi: stateViewAbi, functionName: "getLiquidity", result: liquidity });
        }
        if (sameAddress(to, HOOK) && !behaviour.silentHook) {
          const call = decodeFunctionData({ abi: stablePairHookAbi, data });
          if (call.functionName !== "feeConfig") return "0x";
          const result = [16757000, 3000, 100, poolOf(call.args[0]).reference] as const;
          return encodeFunctionResult({ abi: stablePairHookAbi, functionName: "feeConfig", result });
        }
        if (sameAddress(to, SWAPPER)) {
          const call = decodeFunctionData({ abi: poolSwapTestAbi, data });
          if (call.functionName === "manager") {
            const result = behaviour.swapperManager ?? POOL_MANAGER;
            return encodeFunctionResult({ abi: poolSwapTestAbi, functionName: "manager", result });
          }
          const [key, swapParams] = call.args;
          if (behaviour.revertSwapOf?.toLowerCase() === idOf(key)) {
            const args = [poolOf(idOf(key)).spot, swapParams.sqrtPriceLimitX96] as const;
            const revert = encodeErrorResult({ abi: poolSwapTestAbi, errorName: "PriceLimitAlreadyExceeded", args });
            throw { code: 3, message: "execution reverted", data: revert };
          }
          return encodeFunctionResult({ abi: poolSwapTestAbi, functionName: "swap", result: 0n });
        }
        return "0x";
      }
      case "eth_getCode":
        return behaviour.swapperCode ?? "0x6080";
      case "eth_fillTransaction":
        throw new Error("fake node: eth_fillTransaction is not supported"); // viem then fills the transaction itself
      case "eth_getTransactionCount":
        return "0x0";
      case "eth_getBlockByNumber":
        return { number: "0x1", timestamp: "0x1", baseFeePerGas: "0x1", transactions: [] };
      case "eth_maxPriorityFeePerGas":
        return "0x1";
      case "eth_estimateGas":
        return "0x30d40";
      case "eth_sendRawTransaction": {
        const [raw] = params as [Hex];
        const transaction = parseTransaction(raw);
        if (!sameAddress(transaction.to ?? "0x", SWAPPER)) throw new Error(`fake node: sent to ${transaction.to}`);
        const call = decodeFunctionData({ abi: poolSwapTestAbi, data: transaction.data ?? "0x" });
        if (call.functionName !== "swap") throw new Error(`fake node: sent ${call.functionName}`);
        sent.push(call.args);
        const [key, swapParams] = call.args;
        const pool = poolOf(idOf(key));
        if (behaviour.swapMoves !== false && pool.liquidity === 0n) pool.spot = swapParams.sqrtPriceLimitX96;
        if (behaviour.referenceAfterSwap !== undefined) pool.reference = behaviour.referenceAfterSwap;
        return keccak256(raw);
      }
      case "eth_getTransactionReceipt": {
        const [hash] = params as [Hex];
        return {
          transactionHash: hash,
          blockHash: `0x${"bb".repeat(32)}`,
          blockNumber: "0x2",
          transactionIndex: "0x0",
          status: "0x1",
          type: "0x2",
          to: SWAPPER,
          contractAddress: null,
          gasUsed: "0x5208",
          cumulativeGasUsed: "0x5208",
          effectiveGasPrice: "0x1",
          logs: [],
        };
      }
      default:
        throw new Error(`fake node: unexpected ${method}`);
    }
  };
  const transport = custom({ request }, { retryCount: 0 });
  const client = createPublicClient({ chain: robinhood, transport });
  const account = privateKeyToAccount(generatePrivateKey());
  const wallet = createWalletClient({ account, chain: robinhood, transport });
  return { client, wallet, methods, callBlocks, sent, state };
}

describe("alignPass", () => {
  // NVDA (stock is currency0) 199 bps below its reference and MSFT (QQQ is currency0) 201 bps above, both empty
  const bothOff = {
    [NVDA_ID]: { spot: at(99n), liquidity: 0n, reference: at(100n) },
    [MSFT_ID]: { spot: at(101n), liquidity: 0n, reference: at(100n) },
  };
  const live = { minBps: 25, dryRun: false, swapper: SWAPPER };
  async function run(node: ReturnType<typeof fakeNode>, options: Parameters<typeof alignPass>[1] = live) {
    const lines: string[] = [];
    const deps = { client: node.client, wallet: node.wallet, log: (line: string) => lines.push(line) };
    return { result: await alignPass(deployments, options, deps), lines };
  }

  test("under --dry-run it only reads, then prints each planned swap and its calldata", async () => {
    const node = fakeNode(bothOff);
    const { result, lines } = await run(node, { ...live, dryRun: true });
    expect(node.methods).toEqual(Array(6).fill("eth_call")); // getSlot0, getLiquidity and feeConfig of the two pools
    expect([result.aligned, result.failed, result.skipped]).toEqual([[], [], []]);
    const calldata = (i: number) =>
      encodeFunctionData({ abi: poolSwapTestAbi, functionName: "swap", args: result.alignments[i]!.swap! });
    expect(lines.slice(2)).toEqual([
      `dry run, not sent: swap for NVDA (zeroForOne false, amountSpecified -1, sqrtPriceLimitX96 ${at(
        100n,
      )}) on ${SWAPPER}`,
      `calldata ${calldata(0)}`,
      `dry run, not sent: swap for MSFT (zeroForOne true, amountSpecified -1, sqrtPriceLimitX96 ${at(
        100n,
      )}) on ${SWAPPER}`,
      `calldata ${calldata(1)}`,
      "dry run: 2 empty pools to align, nothing sent",
    ]);
    expect(decodeFunctionData({ abi: poolSwapTestAbi, data: calldata(1) }).args).toEqual([
      msft.key,
      { zeroForOne: true, amountSpecified: -1n, sqrtPriceLimitX96: at(100n) },
      { takeClaims: false, settleUsingBurn: false },
      "0x",
    ]);
  });

  test("a dry run without a swapper still prints the plan", async () => {
    const { lines } = await run(fakeNode(bothOff), { minBps: 25, dryRun: true, swapper: undefined });
    expect(lines[2]).toEndWith(") on the --swapper");
  });

  test("live, it simulates and sends each swap, then finds the pool on its reference at the receipt's block", async () => {
    const node = fakeNode(bothOff);
    const { result, lines } = await run(node);
    expect([result.aligned, result.failed]).toEqual([["NVDA", "MSFT"], []]);
    expect(node.sent).toEqual(result.alignments.map((a) => a.swap!));
    expect([node.state.get(NVDA_ID)!.spot, node.state.get(MSFT_ID)!.spot]).toEqual([at(100n), at(100n)]);
    expect(node.callBlocks.slice(-3)).toEqual(["0x2", "0x2", "0x2"]); // the re-read of MSFT, at the receipt's block
    const confirmed = lines.filter((line) => line.startsWith("confirmed "));
    expect(confirmed.map((line) => line.replace(/0x[0-9a-f]{64}/, "<hash>"))).toEqual([
      "confirmed <hash> in block 2: NVDA price +0.00 bps off its reference",
      "confirmed <hash> in block 2: MSFT price +0.00 bps off its reference",
    ]);
    expect(lines.at(-1)).toBe("aligned 2 of 2 empty pools");
  });

  test("a swap that does not land fails its pool, saying where the price stopped, and the next pool still goes", async () => {
    const { result, lines } = await run(fakeNode(bothOff, { swapMoves: false }));
    expect([result.aligned, result.failed]).toEqual([[], ["NVDA", "MSFT"]]);
    const failure = lines.find((line) => line.startsWith("FAIL NVDA"))!.replace(/after 0x[0-9a-f]{64}/, "after <hash>");
    expect(failure).toBe(
      `FAIL NVDA ${NVDA_ID}: price -199.00 bps off its reference after <hash> (block 2): ` +
        `its price stopped at ${at(99n)}, not the planned ${at(100n)}`,
    );
    expect(lines.at(-1)).toBe("aligned 0 of 2 empty pools; left off their reference: NVDA, MSFT");
  });

  test("a reverted simulation fails only its pool, by the error's name, and sends nothing for it", async () => {
    const node = fakeNode(bothOff, { revertSwapOf: NVDA_ID });
    const { result, lines } = await run(node);
    expect([result.aligned, result.failed]).toEqual([["MSFT"], ["NVDA"]]);
    expect(node.sent.map(([key]) => key)).toEqual([msft.key]);
    expect(lines).toContain(
      `FAIL NVDA ${NVDA_ID}: The contract function "swap" reverted: PriceLimitAlreadyExceeded(${at(99n)}, ${at(100n)})`,
    );
  });

  test("a reference the keeper moved while the swap was in flight is reported as such", async () => {
    const node = fakeNode(
      { ...bothOff, [NVDA_ID]: { spot: at(100n), liquidity: 0n, reference: at(100n) } },
      {
        referenceAfterSwap: at(102n),
      },
    );
    const { result, lines } = await run(node);
    expect([result.aligned, result.failed]).toEqual([[], ["MSFT"]]);
    const failure = lines.find((line) => line.startsWith("FAIL MSFT"))!;
    expect(failure).toEndWith(`its price is on the planned ${at(100n)}, but the reference moved to ${at(102n)}`);
  });

  test("pools with liquidity or within min-bps send nothing, not even a simulation", async () => {
    const node = fakeNode({
      [NVDA_ID]: { spot: at(101n), liquidity: 5n, reference: at(100n) },
      [MSFT_ID]: { spot: at(100n), liquidity: 0n, reference: at(100n) },
    });
    const { result, lines } = await run(node);
    expect(result.alignments.map((a) => a.action)).toEqual(["skip", "none"]);
    expect([result.aligned, result.failed, result.skipped]).toEqual([[], [], ["NVDA"]]);
    expect(node.methods).toEqual(Array(6).fill("eth_call"));
    expect(lines.at(-1)).toBe(
      "no empty pool more than 25 bps off its reference; nothing to send; skipped, having liquidity: NVDA",
    );
  });

  test("a pool with liquidity off band is never sent and is reported next to the aligned ones", async () => {
    const node = fakeNode({ ...bothOff, [NVDA_ID]: { spot: at(99n), liquidity: 5n, reference: at(100n) } });
    const { result, lines } = await run(node);
    expect([result.aligned, result.failed, result.skipped]).toEqual([["MSFT"], [], ["NVDA"]]);
    expect(node.sent.map(([key]) => key)).toEqual([msft.key]);
    expect(lines[0]).toStartWith(`WARN NVDA ${NVDA_ID} liquidity 5,`);
    expect(lines.at(-1)).toBe("aligned 1 of 1 empty pool; skipped, having liquidity: NVDA");
  });

  test("a read that fails names the pool, the call and the contract, and fails the pass", async () => {
    await expect(run(fakeNode(bothOff, { silentHook: true }))).rejects.toThrow(
      `feeConfig of NVDA ${NVDA_ID} on ${HOOK}: The contract function "feeConfig" returned no data ("0x").`,
    );
  });

  test("a live pass with something to send needs the signer and the swapper", async () => {
    const node = fakeNode(bothOff);
    const deps = { client: node.client, log: () => {} };
    await expect(alignPass(deployments, live, deps)).rejects.toThrow("no signer or swapper to send with");
    expect(node.methods).toEqual(Array(6).fill("eth_call"));
  });
});

describe("checkSwapper", () => {
  test("accepts a PoolSwapTest of the PoolManager and refuses no code, another contract or another manager", async () => {
    await expect(checkSwapper(fakeNode({}).client, SWAPPER, POOL_MANAGER)).resolves.toBeUndefined();
    await expect(checkSwapper(fakeNode({}, { swapperCode: "0x" }).client, SWAPPER, POOL_MANAGER)).rejects.toThrow(
      `no contract at --swapper ${SWAPPER}; deploy PoolSwapTest`,
    );
    const other = getAddress("0x6666666666666666666666666666666666666666");
    await expect(checkSwapper(fakeNode({}).client, other, POOL_MANAGER)).rejects.toThrow(
      `--swapper ${other} is not a PoolSwapTest: manager() failed: The contract function "manager" returned no data`,
    );
    const elsewhere = fakeNode({}, { swapperManager: other }).client;
    await expect(checkSwapper(elsewhere, SWAPPER, POOL_MANAGER)).rejects.toThrow(
      `--swapper ${SWAPPER} swaps on PoolManager ${other}, not the deployments file's ${POOL_MANAGER}`,
    );
  });
});

describe("CLI", () => {
  test("parseCli defaults to tooling/deployments/4663.json, no swapper, 25 bps, a 60 s loop, live", () => {
    expect(parseCli([])).toEqual({
      deployments: DEFAULT_DEPLOYMENTS,
      swapper: undefined,
      minBps: 25,
      intervalMs: 60_000,
      dryRun: false,
      once: false,
    });
    const args = [
      "--swapper",
      SWAPPER.toLowerCase(),
      "--min-bps",
      "12.5",
      "--interval",
      "5",
      "--deployments",
      "x.json",
    ];
    expect(parseCli([...args, "--dry-run", "--once"])).toEqual({
      deployments: "x.json",
      swapper: SWAPPER,
      minBps: 12.5,
      intervalMs: 5_000,
      dryRun: true,
      once: true,
    });
    expect(parseCli(["--dry-run"])).toMatchObject({ dryRun: true, once: false, swapper: undefined });
    expect(parseCli(["--min-bps", "0"]).minBps).toBe(0);
  });

  test("parseCli rejects a bad --min-bps, --swapper or --interval and unknown flags", () => {
    for (const bad of ["-1", "lots", "", " ", "NaN", "Infinity"]) {
      expect(() => parseCli([`--min-bps=${bad}`])).toThrow(`--min-bps must be a non-negative number, got ${bad}`);
    }
    for (const bad of ["0x1234", "swapper"]) {
      expect(() => parseCli(["--swapper", bad])).toThrow(`--swapper must be an address, got ${bad}`);
    }
    for (const interval of ["0", "86401", "soon"]) {
      expect(() => parseCli(["--interval", interval])).toThrow(
        `--interval must be between 1 and 86400 seconds, got ${interval}`,
      );
    }
    expect(() => parseCli(["--dryrun"])).toThrow("--dryrun");
  });

  const ALIGNER = join(import.meta.dir, "../src/alignPools.ts");
  const runAligner = (args: string[], env: Record<string, string>) => {
    const inherited: Record<string, string | undefined> = { ...process.env };
    delete inherited.RPC_4663;
    delete inherited.DEPLOYER_KEY_FILE;
    const result = Bun.spawnSync({ cmd: [process.execPath, ALIGNER, ...args], env: { ...inherited, ...env } });
    return { exitCode: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString() };
  };
  const CLOSED_PORT = "http://127.0.0.1:1"; // a run that gets this far stops at its first RPC call

  test("a missing deployments file, a missing RPC_4663 or a bad --min-bps exits 1 with one line", () => {
    const missing = join(mkdtempSync(join(tmpdir(), "align-cli-")), "4663.json");
    expect(runAligner(["--dry-run", "--once", "--deployments", missing], { RPC_4663: CLOSED_PORT })).toEqual({
      exitCode: 1,
      stdout: "",
      stderr: `alignPools: no deployments file at ${missing}; deploy first or pass --deployments <file>\n`,
    });
    expect(runAligner(["--dry-run", "--once"], {})).toEqual({
      exitCode: 1,
      stdout: "",
      stderr: "alignPools: RPC_4663 is not set; point it at a chain 4663 RPC\n",
    });
    expect(runAligner(["--dry-run", "--min-bps", "lots"], { RPC_4663: CLOSED_PORT })).toEqual({
      exitCode: 1,
      stdout: "",
      stderr: "alignPools: --min-bps must be a non-negative number, got lots\n",
    });
  });

  test("--dry-run never reads DEPLOYER_KEY_FILE; a live run needs --swapper before it reads the key", () => {
    const dir = mkdtempSync(join(tmpdir(), "align-cli-"));
    const malformed = join(dir, "malformed.key");
    writeFileSync(malformed, "not a key");
    for (const keyFile of [join(dir, "missing.key"), malformed]) {
      const env = { RPC_4663: CLOSED_PORT, DEPLOYER_KEY_FILE: keyFile };
      const dryRun = runAligner(["--dry-run", "--once", "--swapper", SWAPPER], env);
      expect(dryRun.exitCode).toBe(1);
      expect(dryRun.stdout).toContain(`swapper ${SWAPPER}, once, dry run\n`);
      expect(dryRun.stderr).toStartWith("alignPools: HTTP request failed.");
      expect(dryRun.stderr).not.toContain(keyFile);
      // controls: a live run without --swapper stops before the key, and with it at the key, printing nothing
      expect(runAligner(["--once"], env)).toEqual({
        exitCode: 1,
        stdout: "",
        stderr:
          "alignPools: a live run needs --swapper <PoolSwapTest address> (see the header to deploy one), " +
          "or pass --dry-run\n",
      });
      expect(runAligner(["--once", "--swapper", SWAPPER], env)).toEqual({
        exitCode: 1,
        stdout: "",
        stderr: expect.stringContaining(keyFile),
      });
    }
  }, 30_000);
});
