import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import {
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  createPublicClient,
  createWalletClient,
  custom,
  decodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeErrorResult,
  encodeFunctionData,
  encodeFunctionResult,
  getAbiItem,
  getAddress,
  parseAbiParameters,
  toFunctionSelector,
  type Address,
  type Hex,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { robinhood } from "viem/chains";
import { CONSTITUENTS, INDEX_TOKEN } from "../src/constituents";
import { stablePairHookAbi } from "../src/hookAbi";
import {
  DEFAULT_DEPLOYMENTS,
  describeError,
  formatDecision,
  freshReferences,
  keyFilePath,
  loadAccount,
  loadDeployments,
  parseCli,
  parseDeployments,
  planUpdates,
  tick,
} from "../src/keeper";
import { computeReference } from "../src/sqrtPrice";

const ONE = 1_000_000_000n;
const Q96 = 2n ** 96n;
const stock = (symbol: string) => CONSTITUENTS.find((c) => c.symbol === symbol)!.address;
const NVDA = stock("NVDA"); // sorts below QQQ, so it is currency0
const MSFT = stock("MSFT"); // sorts above QQQ, so it is currency1
const PRICES = { [NVDA.toLowerCase()]: 190, [MSFT.toLowerCase()]: 520, [INDEX_TOKEN.toLowerCase()]: 610 };
const id = (byte: string) => `0x${byte.repeat(32)}` as Hex;
const HOOK = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd";

describe("planUpdates", () => {
  test("only pools whose reference moved more than the threshold are included", () => {
    const cur = [
      { poolId: "0x01", referenceSqrtPriceX96: 1_000_000_000n },
      { poolId: "0x02", referenceSqrtPriceX96: 1_000_000_000n },
    ];
    const fresh = [
      { poolId: "0x01", referenceSqrtPriceX96: 1_000_500_000n },
      { poolId: "0x02", referenceSqrtPriceX96: 1_003_000_000n },
    ]; // +0.05% sqrt = +0.1% price; +0.3% sqrt = +0.6% price
    const plan = planUpdates(cur, fresh, 20);
    expect(plan.poolIds).toEqual(["0x02"]);
  });

  test("a move of exactly the threshold is not included and one unit more is, in either direction", () => {
    const cur = ["0x01", "0x02", "0x03", "0x04"].map((poolId) => ({ poolId, referenceSqrtPriceX96: ONE }));
    const fresh = [
      { poolId: "0x01", referenceSqrtPriceX96: 1_001_000_000n }, // +0.1% sqrt = exactly 20 price bps
      { poolId: "0x02", referenceSqrtPriceX96: 1_001_000_001n },
      { poolId: "0x03", referenceSqrtPriceX96: 999_000_000n }, // -0.1% sqrt = exactly 20 price bps
      { poolId: "0x04", referenceSqrtPriceX96: 998_999_999n },
    ];
    const plan = planUpdates(cur, fresh, 20);
    expect(plan.poolIds).toEqual(["0x02", "0x04"]);
    expect(plan.decisions.map((d) => [d.poolId, d.moveBps, d.update])).toEqual([
      ["0x01", 20, false],
      ["0x02", 20.00002, true],
      ["0x03", 20, false],
      ["0x04", 20.00002, true],
    ]);
  });

  test("a move of exactly the max move proceeds and one unit more is skipped as a suspect price, either way", () => {
    const cur = ["0x01", "0x02", "0x03", "0x04"].map((poolId) => ({ poolId, referenceSqrtPriceX96: ONE }));
    const fresh = [
      { poolId: "0x01", referenceSqrtPriceX96: 1_100_000_000n }, // +10% sqrt = exactly 2000 price bps
      { poolId: "0x02", referenceSqrtPriceX96: 1_100_000_001n },
      { poolId: "0x03", referenceSqrtPriceX96: 900_000_000n }, // -10% sqrt = exactly 2000 price bps
      { poolId: "0x04", referenceSqrtPriceX96: 899_999_999n },
    ];
    const plan = planUpdates(cur, fresh, 20, { maxMoveBps: 2000 });
    expect(plan.poolIds).toEqual(["0x01", "0x03"]);
    expect(plan.decisions.map((d) => [d.poolId, d.moveBps, d.exceedsMaxMove, d.update])).toEqual([
      ["0x01", 2000, false, true],
      ["0x02", 2000.00002, true, false],
      ["0x03", 2000, false, true],
      ["0x04", 2000.00002, true, false],
    ]);
    expect(planUpdates(cur, fresh, 20).poolIds).toEqual(["0x01", "0x03"]); // 2000 bps is the default
  });

  test("force sends a move beyond the max move, still flagged", () => {
    const cur = [{ poolId: "0x01", referenceSqrtPriceX96: ONE }];
    const fresh = [{ poolId: "0x01", referenceSqrtPriceX96: 2n * ONE }]; // +100% sqrt = 20000 price bps
    expect(planUpdates(cur, fresh, 20).poolIds).toEqual([]);
    const plan = planUpdates(cur, fresh, 20, { force: true });
    expect(plan.poolIds).toEqual(["0x01"]);
    expect(plan.configs).toEqual([{ referenceSqrtPriceX96: 2n * ONE }]);
    expect(plan.decisions).toEqual([
      { poolId: "0x01", current: ONE, fresh: 2n * ONE, moveBps: 20000, exceedsMaxMove: true, update: true },
    ]);
  });

  test("a pool skipped for its move leaves the others planned", () => {
    const current = [
      { poolId: id("11"), k: 1, optimalFeeE6: 3000, targetMultiplier: 100, referenceSqrtPriceX96: ONE },
      { poolId: id("22"), k: 2, optimalFeeE6: 5000, targetMultiplier: 100, referenceSqrtPriceX96: ONE },
      { poolId: id("33"), k: 3, optimalFeeE6: 4000, targetMultiplier: 50, referenceSqrtPriceX96: ONE },
    ];
    const fresh = [
      { poolId: id("11"), referenceSqrtPriceX96: ONE + 5_000_000n }, // 100 bps
      { poolId: id("22"), referenceSqrtPriceX96: 3n * ONE }, // 40000 bps: suspect
      { poolId: id("33"), referenceSqrtPriceX96: ONE - 5_000_000n }, // 100 bps
    ];
    const plan = planUpdates(current, fresh, 20);
    expect(plan.poolIds).toEqual([id("11"), id("33")]);
    expect(plan.configs).toEqual([
      { k: 1, optimalFeeE6: 3000, targetMultiplier: 100, referenceSqrtPriceX96: ONE + 5_000_000n },
      { k: 3, optimalFeeE6: 4000, targetMultiplier: 50, referenceSqrtPriceX96: ONE - 5_000_000n },
    ]);
    expect(plan.decisions.map((d) => [d.exceedsMaxMove, d.update])).toEqual([
      [false, true],
      [true, false],
      [false, true],
    ]);
  });

  test("an unchanged pool is never included, even at threshold 0", () => {
    const cur = [
      { poolId: "0x01", referenceSqrtPriceX96: ONE },
      { poolId: "0x02", referenceSqrtPriceX96: ONE },
    ];
    const fresh = [
      { poolId: "0x01", referenceSqrtPriceX96: ONE },
      { poolId: "0x02", referenceSqrtPriceX96: ONE + 1n },
    ];
    expect(planUpdates(cur, fresh, 0).poolIds).toEqual(["0x02"]);
  });

  test("configs keep k, optimalFeeE6 and targetMultiplier, take the fresh reference and align with poolIds", () => {
    const current = [
      { poolId: id("11"), k: 16757000, optimalFeeE6: 3000, targetMultiplier: 100, referenceSqrtPriceX96: ONE },
      { poolId: id("22"), k: 16000000, optimalFeeE6: 5000, targetMultiplier: 50, referenceSqrtPriceX96: ONE },
      { poolId: id("33"), k: 15000000, optimalFeeE6: 4000, targetMultiplier: 0, referenceSqrtPriceX96: 2n * ONE },
    ];
    // fresh comes in another order and case: pools are matched by id
    const fresh = [
      { poolId: id("33"), referenceSqrtPriceX96: 2n * ONE + 10_000_000n }, // +100 price bps
      { poolId: id("11"), referenceSqrtPriceX96: ONE + 1n },
      { poolId: id("22").toUpperCase().replace("0X", "0x"), referenceSqrtPriceX96: ONE - 5_000_000n }, // -100 price bps
    ];
    const plan = planUpdates(current, fresh, 20);
    expect(plan.poolIds).toEqual([id("22"), id("33")]);
    expect(plan.configs).toEqual([
      { k: 16000000, optimalFeeE6: 5000, targetMultiplier: 50, referenceSqrtPriceX96: ONE - 5_000_000n },
      { k: 15000000, optimalFeeE6: 4000, targetMultiplier: 0, referenceSqrtPriceX96: 2n * ONE + 10_000_000n },
    ]);
    expect(current.map((c) => c.referenceSqrtPriceX96)).toEqual([ONE, ONE, 2n * ONE]);
  });

  test("throws on a pool without a fresh reference, an empty on-chain reference or bad bounds", () => {
    const cur = [{ poolId: "0x01", referenceSqrtPriceX96: ONE }];
    expect(() => planUpdates(cur, [], 20)).toThrow("no fresh reference for pool 0x01");
    expect(() => planUpdates([{ poolId: "0x01", referenceSqrtPriceX96: 0n }], cur, 20)).toThrow(
      "pool 0x01 has no reference on the hook",
    );
    for (const bad of [-1, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(() => planUpdates(cur, cur, bad)).toThrow("thresholdBps must be a non-negative number");
    }
    for (const maxMoveBps of [Number.NaN, Number.POSITIVE_INFINITY, 20, 10]) {
      expect(() => planUpdates(cur, cur, 20, { maxMoveBps })).toThrow(
        "maxMoveBps must be a finite number above thresholdBps (20)",
      );
    }
  });
});

describe("formatDecision", () => {
  const decision = { poolId: id("22"), current: Q96, fresh: 2n * Q96, moveBps: 20000, exceedsMaxMove: true };

  test("a move beyond the max move is a WARN naming the pool, the move in bps and --force", () => {
    const skipped = formatDecision("MSFT", { ...decision, update: false }, 20, 2000);
    expect(skipped).toStartWith(`WARN MSFT ${id("22")} reference ${Q96} (tick 0) -> ${2n * Q96} (tick `);
    expect(skipped).toEndWith("price move 20000.00 bps > max 2000 bps: skipped as a suspect price, --force overrides");
    expect(formatDecision("MSFT", { ...decision, update: true }, 20, 2000)).toEndWith(
      "price move 20000.00 bps > max 2000 bps: sent anyway (--force)",
    );
  });

  test("any other move is a plain line against the threshold", () => {
    const update = formatDecision("NVDA", { ...decision, moveBps: 30, exceedsMaxMove: false, update: true }, 20, 2000);
    expect(update).toStartWith(`NVDA ${id("22")} reference`);
    expect(update).toEndWith("price move 30.00 > 20 bps: update");
    const keep = formatDecision("NVDA", { ...decision, moveBps: 12, exceedsMaxMove: false, update: false }, 20, 2000);
    expect(keep).toEndWith("price move 12.00 <= 20 bps: keep");
  });
});

describe("freshReferences", () => {
  const pools = [
    { symbol: "NVDA", stock: NVDA, poolId: id("11"), currency0: NVDA, currency1: INDEX_TOKEN },
    { symbol: "MSFT", stock: MSFT, poolId: id("22"), currency0: INDEX_TOKEN, currency1: MSFT },
  ];

  test("is sqrt(usd(currency0) / usd(currency1)) whichever side the stock is on", () => {
    const refs = freshReferences(pools, PRICES);
    expect(refs).toEqual([
      { poolId: id("11"), referenceSqrtPriceX96: computeReference(190, 610) },
      { poolId: id("22"), referenceSqrtPriceX96: computeReference(610, 520) },
    ]);
    const price = (sqrtPriceX96: bigint) => (Number(sqrtPriceX96) / 2 ** 96) ** 2; // currency1 per currency0
    expect(price(refs[0]!.referenceSqrtPriceX96)).toBeCloseTo(190 / 610, 9);
    expect(price(refs[1]!.referenceSqrtPriceX96)).toBeCloseTo(610 / 520, 9);
  });

  test("throws when a currency has no valid price", () => {
    expect(() => freshReferences(pools, { ...PRICES, [MSFT.toLowerCase()]: 0 })).toThrow(
      `no valid USD price for ${MSFT}`,
    );
  });
});

describe("hookAbi", () => {
  test("feeConfig returns four named values, not one struct, and decodes a hand-built return value", () => {
    const item = getAbiItem({ abi: stablePairHookAbi, name: "feeConfig" });
    expect(toFunctionSelector(item)).toBe("0xb9629a41"); // cast sig "feeConfig(bytes32)"
    expect(item.outputs.map((o) => `${o.type} ${o.name}`)).toEqual([
      "uint24 k",
      "uint24 optimalFeeE6",
      "uint8 targetMultiplier",
      "uint160 referenceSqrtPriceX96",
    ]);
    const ref = 2n ** 96n + 123_456_789n;
    const data = encodeAbiParameters(parseAbiParameters("uint24, uint24, uint8, uint160"), [16757000, 3000, 100, ref]);
    const decoded = decodeFunctionResult({ abi: stablePairHookAbi, functionName: "feeConfig", data });
    expect(decoded).toEqual([16757000, 3000, 100, ref]);
  });

  test("batchUpdateFeeConfig encodes a 2-pool plan byte for byte like cast calldata", () => {
    const item = getAbiItem({ abi: stablePairHookAbi, name: "batchUpdateFeeConfig" });
    // cast sig "batchUpdateFeeConfig(bytes32[],(uint24,uint24,uint8,uint160)[])"
    expect(toFunctionSelector(item)).toBe("0x8544d33a");
    const current = [
      { poolId: id("aa"), k: 16757000, optimalFeeE6: 3000, targetMultiplier: 100, referenceSqrtPriceX96: 2n ** 96n },
      { poolId: id("bb"), k: 15000000, optimalFeeE6: 5000, targetMultiplier: 50, referenceSqrtPriceX96: 2n ** 95n },
    ];
    const fresh = [
      { poolId: id("aa"), referenceSqrtPriceX96: (2n ** 96n * 101n) / 100n },
      { poolId: id("bb"), referenceSqrtPriceX96: (2n ** 95n * 99n) / 100n },
    ];
    const plan = planUpdates(current, fresh, 20);
    const args = [plan.poolIds, plan.configs] as const;
    const data = encodeFunctionData({ abi: stablePairHookAbi, functionName: "batchUpdateFeeConfig", args });
    // cast calldata "batchUpdateFeeConfig(bytes32[],(uint24,uint24,uint8,uint160)[])" "[0xaa…aa,0xbb…bb]"
    //   "[(16757000,3000,100,80020444139406980969479389839),(15000000,5000,50,39217940444560847108804255416)]"
    const golden = [
      "0x8544d33a",
      "0000000000000000000000000000000000000000000000000000000000000040", // offset of poolIds
      "00000000000000000000000000000000000000000000000000000000000000a0", // offset of feeConfigs
      "0000000000000000000000000000000000000000000000000000000000000002", // poolIds.length
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "0000000000000000000000000000000000000000000000000000000000000002", // feeConfigs.length
      "0000000000000000000000000000000000000000000000000000000000ffb108", // [0].k 16757000
      "0000000000000000000000000000000000000000000000000000000000000bb8", // [0].optimalFeeE6 3000
      "0000000000000000000000000000000000000000000000000000000000000064", // [0].targetMultiplier 100
      "0000000000000000000000000000000000000001028f5c28f5c28f5c28f5c28f", // [0].referenceSqrtPriceX96
      "0000000000000000000000000000000000000000000000000000000000e4e1c0", // [1].k 15000000
      "0000000000000000000000000000000000000000000000000000000000001388", // [1].optimalFeeE6 5000
      "0000000000000000000000000000000000000000000000000000000000000032", // [1].targetMultiplier 50
      "00000000000000000000000000000000000000007eb851eb851eb851eb851eb8", // [1].referenceSqrtPriceX96
    ].join("") as Hex;
    expect(data).toBe(golden);
    expect(decodeFunctionData({ abi: stablePairHookAbi, data }).args).toEqual(args);
  });
});

describe("describeError", () => {
  const reverted = (data: Hex) =>
    new ContractFunctionExecutionError(
      new ContractFunctionRevertedError({ abi: stablePairHookAbi, data, functionName: "batchUpdateFeeConfig" }),
      {
        abi: stablePairHookAbi,
        functionName: "batchUpdateFeeConfig",
        args: [[id("11")], []],
        contractAddress: getAddress(HOOK),
      },
    );

  test("names the hook's custom errors with their arguments on one line", () => {
    const notInitialized = encodeErrorResult({
      abi: stablePairHookAbi,
      errorName: "PoolNotInitialized",
      args: [id("11")],
    });
    expect(describeError(reverted(notInitialized))).toBe(
      `The contract function "batchUpdateFeeConfig" reverted: PoolNotInitialized(${id("11")})`,
    );
    const signer = privateKeyToAccount(generatePrivateKey()).address;
    const configManagerRole = "0xbbfb55d933c2bfa638763473275b1d84c4418e58d26cf9d2cd5758237756d9f0";
    const unauthorized = encodeErrorResult({
      abi: stablePairHookAbi,
      errorName: "AccessControlUnauthorizedAccount",
      args: [signer, configManagerRole],
    });
    expect(describeError(reverted(unauthorized))).toBe(
      `The contract function "batchUpdateFeeConfig" reverted: AccessControlUnauthorizedAccount(${signer}, ${configManagerRole})`,
    );
  });

  test("keeps viem's short message for other failures and the message of plain errors", () => {
    const noData = new ContractFunctionExecutionError(
      new ContractFunctionZeroDataError({ functionName: "feeConfig" }),
      {
        abi: stablePairHookAbi,
        functionName: "feeConfig",
        args: [id("11")],
        contractAddress: getAddress(HOOK),
      },
    );
    expect(describeError(noData)).toBe('The contract function "feeConfig" returned no data ("0x").');
    expect(describeError(new Error("two\n  lines"))).toBe("two lines");
    expect(describeError("text")).toBe("text");
  });
});

const DEPLOYMENTS = {
  chainId: 4663,
  hook: HOOK,
  vault: "0x1111111111111111111111111111111111111111",
  indexToken: INDEX_TOKEN,
  positionManager: "0x2222222222222222222222222222222222222222",
  poolManager: "0x3333333333333333333333333333333333333333",
  stateView: "0x4444444444444444444444444444444444444444",
  constituents: [
    {
      symbol: "NVDA",
      stock: NVDA.toLowerCase(),
      poolId: id("11"),
      currency0: NVDA,
      currency1: INDEX_TOKEN,
      tickSpacing: 10,
      tickLower: -14000,
      tickUpper: -9000,
      targetBps: 1719,
    },
    {
      symbol: "MSFT",
      stock: MSFT,
      poolId: id("22"),
      currency0: INDEX_TOKEN,
      currency1: MSFT,
      tickSpacing: 10,
      tickLower: -100,
      tickUpper: 2700,
      targetBps: 1172,
    },
  ],
};

describe("deployments", () => {
  test("parseDeployments keeps the hook and each pool's symbol, stock, poolId and currencies, checksummed", () => {
    expect(parseDeployments(DEPLOYMENTS)).toEqual({
      hook: getAddress(HOOK),
      pools: [
        { symbol: "NVDA", stock: NVDA, poolId: id("11"), currency0: NVDA, currency1: INDEX_TOKEN },
        { symbol: "MSFT", stock: MSFT, poolId: id("22"), currency0: INDEX_TOKEN, currency1: MSFT },
      ],
    });
  });

  test("parseDeployments rejects files that would read the wrong pool or invert a reference", () => {
    const withPool = (i: number, patch: Record<string, unknown>) => ({
      ...DEPLOYMENTS,
      constituents: DEPLOYMENTS.constituents.map((c, j) => (j === i ? { ...c, ...patch } : c)),
    });
    const cases: [unknown, string][] = [
      [null, "deployments: not a JSON object"],
      [{ ...DEPLOYMENTS, chainId: 1 }, "deployments: chainId is 1, expected 4663"],
      [{ ...DEPLOYMENTS, hook: "0x1234" }, "deployments: hook is not an address"],
      [{ ...DEPLOYMENTS, constituents: [] }, "deployments: constituents must be a non-empty array"],
      [withPool(0, { symbol: "" }), "deployments: constituents[0].symbol must be a non-empty string"],
      [withPool(0, { poolId: "0x1234" }), "deployments: constituents[0] (NVDA).poolId must be a 32-byte hex string"],
      [withPool(1, { stock: "0xnope" }), "deployments: constituents[1] (MSFT).stock is not an address"],
      [
        withPool(0, { currency0: INDEX_TOKEN, currency1: NVDA }),
        "deployments: constituents[0] (NVDA): currency0 must sort below currency1",
      ],
      [withPool(0, { currency1: MSFT }), `deployments: constituents[0] (NVDA): neither currency is ${INDEX_TOKEN}`],
      [withPool(1, { stock: NVDA }), `deployments: constituents[1] (MSFT): stock ${NVDA} is not the pool's ${MSFT}`],
    ];
    for (const [raw, message] of cases) expect(() => parseDeployments(raw)).toThrow(message);
  });

  test("loadDeployments reads a file and names a missing one", () => {
    const dir = mkdtempSync(join(tmpdir(), "keeper-deployments-"));
    const path = join(dir, "4663.json");
    writeFileSync(path, JSON.stringify(DEPLOYMENTS));
    expect(loadDeployments(path)).toEqual(parseDeployments(DEPLOYMENTS));
    const missing = join(dir, "missing.json");
    expect(() => loadDeployments(missing)).toThrow(
      `no deployments file at ${missing}; deploy first or pass --deployments <file>`,
    );
  });
});

describe("tick", () => {
  type FeeConfigResult = readonly [number, number, number, bigint];
  const deployments = parseDeployments(DEPLOYMENTS); // NVDA (currency0) and MSFT (currency1) against QQQ
  const fresh = freshReferences(deployments.pools, PRICES);
  // a distinct k, optimalFeeE6 and targetMultiplier per pool, so a swapped field cannot pass; references ~200 bps off
  const onChain: Record<Hex, FeeConfigResult> = {
    [id("11")]: [16757000, 3000, 100, (fresh[0]!.referenceSqrtPriceX96 * 100n) / 101n],
    [id("22")]: [15000000, 5000, 50, (fresh[1]!.referenceSqrtPriceX96 * 101n) / 100n],
  };
  const options = { thresholdBps: 20, maxMoveBps: 2000, force: false, dryRun: true };
  const hook = getAddress(HOOK);

  /**
   * A chain 4663 node on viem's custom transport that records every method. It answers feeConfig from `configs`
   * (no data for other pools, like an address without code), lets the batchUpdateFeeConfig simulation pass and
   * refuses to broadcast.
   */
  function fakeNode(configs: Record<Hex, FeeConfigResult>) {
    const methods: string[] = [];
    const request = async ({ method, params }: { method: string; params?: unknown }) => {
      methods.push(method);
      switch (method) {
        case "eth_call": {
          const [{ data }] = params as [{ data: Hex }];
          const call = decodeFunctionData({ abi: stablePairHookAbi, data });
          if (call.functionName !== "feeConfig") return "0x";
          const result = configs[call.args[0]];
          return result ? encodeFunctionResult({ abi: stablePairHookAbi, functionName: "feeConfig", result }) : "0x";
        }
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
        case "eth_sendRawTransaction":
          throw new Error("fake node: not broadcasting");
        default:
          throw new Error(`fake node: unexpected ${method}`);
      }
    };
    const transport = custom({ request }, { retryCount: 0 });
    const client = createPublicClient({ chain: robinhood, transport });
    const account = privateKeyToAccount(generatePrivateKey());
    const wallet = createWalletClient({ account, chain: robinhood, transport });
    return { client, wallet, methods };
  }

  test("maps feeConfig's four values to the right config fields and, under --dry-run, only reads", async () => {
    const node = fakeNode(onChain);
    const lines: string[] = [];
    const priced: Address[][] = [];
    const plan = await tick(deployments, options, {
      client: node.client,
      wallet: node.wallet, // present, and still unused by a dry run
      fetchPrices: async (addresses) => {
        priced.push([...addresses]);
        return PRICES;
      },
      log: (line) => lines.push(line),
    });
    expect(plan.configs).toEqual([
      {
        k: 16757000,
        optimalFeeE6: 3000,
        targetMultiplier: 100,
        referenceSqrtPriceX96: fresh[0]!.referenceSqrtPriceX96,
      },
      { k: 15000000, optimalFeeE6: 5000, targetMultiplier: 50, referenceSqrtPriceX96: fresh[1]!.referenceSqrtPriceX96 },
    ]);
    expect(priced).toEqual([[INDEX_TOKEN, NVDA, MSFT]]);
    expect(node.methods).toEqual(["eth_call", "eth_call"]); // the two feeConfig reads: no simulation, nothing sent
    expect(lines.at(-2)).toBe(`dry run, not sent: batchUpdateFeeConfig on ${hook} for 2 pools`);
    const calldata = lines.at(-1)!.replace(/^calldata /, "") as Hex;
    expect(decodeFunctionData({ abi: stablePairHookAbi, data: calldata }).args).toEqual([plan.poolIds, plan.configs]);
  });

  test("without --dry-run the same pass simulates, then broadcasts (the control for the test above)", async () => {
    const node = fakeNode(onChain);
    const deps = { client: node.client, wallet: node.wallet, fetchPrices: async () => PRICES, log: () => {} };
    await expect(tick(deployments, { ...options, dryRun: false }, deps)).rejects.toThrow("fake node: not broadcasting");
    expect(node.methods.slice(0, 3)).toEqual(["eth_call", "eth_call", "eth_call"]); // two reads, then the simulation
    expect(node.methods.at(-1)).toBe("eth_sendRawTransaction");
  });

  test("a feeConfig read that returns no data fails the pass, naming the pool and the hook", async () => {
    const node = fakeNode({ [id("11")]: onChain[id("11")]! });
    const deps = { client: node.client, fetchPrices: async () => PRICES, log: () => {} };
    await expect(tick(deployments, options, deps)).rejects.toThrow(
      `feeConfig of MSFT ${id("22")} on ${hook}: The contract function "feeConfig" returned no data ("0x").`,
    );
  });
});

describe("CLI", () => {
  test("parseCli defaults to a 60 s loop, 20 bps threshold, 2000 bps max move and tooling/deployments/4663.json", () => {
    expect(DEFAULT_DEPLOYMENTS).toBe(join(import.meta.dir, "../deployments/4663.json"));
    expect(parseCli([])).toEqual({
      intervalMs: 60_000,
      thresholdBps: 20,
      maxMoveBps: 2000,
      force: false,
      dryRun: false,
      once: false,
      deployments: DEFAULT_DEPLOYMENTS,
    });
    const args = ["--interval", "5", "--threshold-bps", "12.5", "--max-move-bps", "500", "--force"];
    expect(parseCli([...args, "--dry-run", "--once", "--deployments", "x.json"])).toEqual({
      intervalMs: 5_000,
      thresholdBps: 12.5,
      maxMoveBps: 500,
      force: true,
      dryRun: true,
      once: true,
      deployments: "x.json",
    });
    expect([parseCli(["--interval", "1"]), parseCli(["--interval", "86400"])].map((o) => o.intervalMs)).toEqual([
      1_000, 86_400_000,
    ]);
  });

  test("parseCli rejects an interval outside 1-86400 s, a negative threshold, a bad max move and unknown flags", () => {
    for (const interval of ["0", "0.5", "86401", "soon", "Infinity"]) {
      expect(() => parseCli(["--interval", interval])).toThrow(
        `--interval must be between 1 and 86400 seconds, got ${interval}`,
      );
    }
    expect(() => parseCli(["--threshold-bps=-1"])).toThrow("--threshold-bps must be a non-negative number, got -1");
    for (const maxMove of ["Infinity", "NaN", "lots", "20", "5"]) {
      expect(() => parseCli(["--max-move-bps", maxMove])).toThrow(
        `--max-move-bps must be a finite number above --threshold-bps (20), got ${maxMove}`,
      );
    }
    expect(() => parseCli(["--threshold-bps", "30", "--max-move-bps", "25"])).toThrow(
      "--max-move-bps must be a finite number above --threshold-bps (30), got 25",
    );
    expect(() => parseCli(["--dryrun"])).toThrow("--dryrun");
  });

  const KEEPER = join(import.meta.dir, "../src/keeper.ts");
  const runKeeper = (args: string[], env: Record<string, string>) => {
    const inherited: Record<string, string | undefined> = { ...process.env };
    delete inherited.RPC_4663;
    delete inherited.DEPLOYER_KEY_FILE;
    const result = Bun.spawnSync({ cmd: [process.execPath, KEEPER, ...args], env: { ...inherited, ...env } });
    return { exitCode: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString() };
  };

  test("a missing deployments file exits 1 with one line, before any RPC is set up", () => {
    const missing = join(mkdtempSync(join(tmpdir(), "keeper-cli-")), "4663.json");
    const result = runKeeper(["--dry-run", "--once", "--deployments", missing], { RPC_4663: "http://127.0.0.1:1" });
    expect(result).toEqual({
      exitCode: 1,
      stdout: "",
      stderr: `keeper: no deployments file at ${missing}; deploy first or pass --deployments <file>\n`,
    });
  });

  test("a missing RPC_4663 exits 1 with one line", () => {
    const path = join(mkdtempSync(join(tmpdir(), "keeper-cli-")), "4663.json");
    writeFileSync(path, JSON.stringify(DEPLOYMENTS));
    expect(runKeeper(["--dry-run", "--once", "--deployments", path], {})).toEqual({
      exitCode: 1,
      stdout: "",
      stderr: "keeper: RPC_4663 is not set; point it at a chain 4663 RPC\n",
    });
  });

  test("--dry-run never reads DEPLOYER_KEY_FILE, whether it is missing or malformed", () => {
    const dir = mkdtempSync(join(tmpdir(), "keeper-cli-"));
    const deployments = join(dir, "4663.json");
    writeFileSync(deployments, JSON.stringify(DEPLOYMENTS));
    const malformed = join(dir, "malformed.key");
    writeFileSync(malformed, "not a key");
    for (const keyFile of [join(dir, "missing.key"), malformed]) {
      // RPC_4663 is a closed local port, so a run that gets past the key stops at its first RPC call
      const env = { RPC_4663: "http://127.0.0.1:1", DEPLOYER_KEY_FILE: keyFile };
      const dryRun = runKeeper(["--dry-run", "--once", "--deployments", deployments], env);
      expect(dryRun.exitCode).toBe(1);
      expect(dryRun.stdout).toContain(", dry run\n");
      expect(dryRun.stderr).toStartWith("keeper: HTTP request failed.");
      expect(dryRun.stderr).not.toContain(keyFile);
      // control: without --dry-run the same run stops at the key, before printing anything
      expect(runKeeper(["--once", "--deployments", deployments], env)).toEqual({
        exitCode: 1,
        stdout: "",
        stderr: expect.stringContaining(keyFile),
      });
    }
  }, 30_000);
});

describe("signer key", () => {
  test("DEPLOYER_KEY_FILE defaults to ~/.uniswap-hackathon/deployer.key and expands a leading ~", () => {
    expect(keyFilePath({})).toBe(join(homedir(), ".uniswap-hackathon/deployer.key"));
    expect(keyFilePath({ DEPLOYER_KEY_FILE: "~/k.key" })).toBe(join(homedir(), "k.key"));
    expect(keyFilePath({ DEPLOYER_KEY_FILE: "/abs/k.key" })).toBe("/abs/k.key");
  });

  test("loadAccount reads a hex key with or without 0x and never echoes a malformed one", () => {
    const dir = mkdtempSync(join(tmpdir(), "keeper-key-"));
    const write = (name: string, text: string) => {
      const path = join(dir, name);
      writeFileSync(path, text);
      return path;
    };
    const key = generatePrivateKey();
    const { address } = privateKeyToAccount(key);
    expect(loadAccount(write("prefixed.key", `${key}\n`)).address).toBe(address);
    expect(loadAccount(write("bare.key", key.slice(2))).address).toBe(address);
    const malformed = write("malformed.key", "0xdeadbeefcafe");
    expect(() => loadAccount(malformed)).toThrow(new Error(`${malformed} does not hold a 32-byte hex private key`));
    const missing = join(dir, "missing.key");
    expect(() => loadAccount(missing)).toThrow(
      new Error(`cannot read the signer key at ${missing} (set DEPLOYER_KEY_FILE): ENOENT`),
    );
  });

  test("an out-of-range key is rejected without echoing its bytes or the curve library's decimal", () => {
    const dir = mkdtempSync(join(tmpdir(), "keeper-key-"));
    const messageOf = (fn: () => unknown) => {
      try {
        fn();
      } catch (error) {
        return (error as Error).message;
      }
      throw new Error("expected a throw");
    };
    for (const byte of ["00", "ff"]) {
      const key = `0x${byte.repeat(32)}` as const;
      const decimal = BigInt(key).toString();
      expect(messageOf(() => privateKeyToAccount(key))).toContain(`got ${decimal}`); // what the rewrap hides
      const path = join(dir, `${byte}.key`);
      writeFileSync(path, key);
      const message = messageOf(() => loadAccount(path));
      expect(message).toBe(`${path} does not hold a valid secp256k1 private key`);
      expect(message).not.toContain(byte.repeat(32));
      if (decimal !== "0") expect(message).not.toContain(decimal);
    }
  });
});
