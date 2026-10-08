import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import {
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  decodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeErrorResult,
  encodeFunctionData,
  getAbiItem,
  getAddress,
  parseAbiParameters,
  toFunctionSelector,
  type Hex,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { CONSTITUENTS, INDEX_TOKEN } from "../src/constituents";
import { stablePairHookAbi } from "../src/hookAbi";
import {
  DEFAULT_DEPLOYMENTS,
  describeError,
  freshReferences,
  keyFilePath,
  loadAccount,
  loadDeployments,
  parseCli,
  parseDeployments,
  planUpdates,
} from "../src/keeper";
import { computeReference } from "../src/sqrtPrice";

const ONE = 1_000_000_000n;
const stock = (symbol: string) => CONSTITUENTS.find((c) => c.symbol === symbol)!.address;
const NVDA = stock("NVDA"); // sorts below QQQ, so it is currency0
const MSFT = stock("MSFT"); // sorts above QQQ, so it is currency1
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

  test("throws on a pool without a fresh reference, an empty on-chain reference or a bad threshold", () => {
    const cur = [{ poolId: "0x01", referenceSqrtPriceX96: ONE }];
    expect(() => planUpdates(cur, [], 20)).toThrow("no fresh reference for pool 0x01");
    expect(() => planUpdates([{ poolId: "0x01", referenceSqrtPriceX96: 0n }], cur, 20)).toThrow(
      "pool 0x01 has no reference on the hook",
    );
    for (const bad of [-1, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(() => planUpdates(cur, cur, bad)).toThrow("thresholdBps must be a non-negative number");
    }
  });
});

describe("freshReferences", () => {
  const pools = [
    { symbol: "NVDA", stock: NVDA, poolId: id("11"), currency0: NVDA, currency1: INDEX_TOKEN },
    { symbol: "MSFT", stock: MSFT, poolId: id("22"), currency0: INDEX_TOKEN, currency1: MSFT },
  ];
  const prices = { [NVDA.toLowerCase()]: 190, [MSFT.toLowerCase()]: 520, [INDEX_TOKEN.toLowerCase()]: 610 };

  test("is sqrt(usd(currency0) / usd(currency1)) whichever side the stock is on", () => {
    const refs = freshReferences(pools, prices);
    expect(refs).toEqual([
      { poolId: id("11"), referenceSqrtPriceX96: computeReference(190, 610) },
      { poolId: id("22"), referenceSqrtPriceX96: computeReference(610, 520) },
    ]);
    const price = (sqrtPriceX96: bigint) => (Number(sqrtPriceX96) / 2 ** 96) ** 2; // currency1 per currency0
    expect(price(refs[0]!.referenceSqrtPriceX96)).toBeCloseTo(190 / 610, 9);
    expect(price(refs[1]!.referenceSqrtPriceX96)).toBeCloseTo(610 / 520, 9);
  });

  test("throws when a currency has no valid price", () => {
    expect(() => freshReferences(pools, { ...prices, [MSFT.toLowerCase()]: 0 })).toThrow(
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

  test("batchUpdateFeeConfig takes (bytes32[], (uint24,uint24,uint8,uint160)[]) and round-trips a plan", () => {
    const item = getAbiItem({ abi: stablePairHookAbi, name: "batchUpdateFeeConfig" });
    // cast sig "batchUpdateFeeConfig(bytes32[],(uint24,uint24,uint8,uint160)[])"
    expect(toFunctionSelector(item)).toBe("0x8544d33a");
    const current = [
      { poolId: id("aa"), k: 16757000, optimalFeeE6: 3000, targetMultiplier: 100, referenceSqrtPriceX96: 2n ** 95n },
      { poolId: id("bb"), k: 16757000, optimalFeeE6: 5000, targetMultiplier: 100, referenceSqrtPriceX96: 2n ** 97n },
    ];
    const fresh = current.map((c) => ({
      poolId: c.poolId,
      referenceSqrtPriceX96: (c.referenceSqrtPriceX96 * 101n) / 100n,
    }));
    const plan = planUpdates(current, fresh, 20);
    const args = [plan.poolIds, plan.configs] as const;
    const data = encodeFunctionData({ abi: stablePairHookAbi, functionName: "batchUpdateFeeConfig", args });
    expect(decodeFunctionData({ abi: stablePairHookAbi, data })).toEqual({
      functionName: "batchUpdateFeeConfig",
      args: [
        [id("aa"), id("bb")],
        [
          { k: 16757000, optimalFeeE6: 3000, targetMultiplier: 100, referenceSqrtPriceX96: (2n ** 95n * 101n) / 100n },
          { k: 16757000, optimalFeeE6: 5000, targetMultiplier: 100, referenceSqrtPriceX96: (2n ** 97n * 101n) / 100n },
        ],
      ],
    });
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

describe("CLI", () => {
  test("parseCli defaults to a 60 s loop at 20 bps over tooling/deployments/4663.json, sending", () => {
    expect(DEFAULT_DEPLOYMENTS).toBe(join(import.meta.dir, "../deployments/4663.json"));
    expect(parseCli([])).toEqual({
      intervalMs: 60_000,
      thresholdBps: 20,
      dryRun: false,
      once: false,
      deployments: DEFAULT_DEPLOYMENTS,
    });
    const args = ["--interval", "5", "--threshold-bps", "12.5", "--dry-run", "--once", "--deployments", "x.json"];
    expect(parseCli(args)).toEqual({
      intervalMs: 5_000,
      thresholdBps: 12.5,
      dryRun: true,
      once: true,
      deployments: "x.json",
    });
  });

  test("parseCli rejects a non-positive interval, a negative threshold and unknown flags", () => {
    expect(() => parseCli(["--interval", "0"])).toThrow("--interval must be a positive number of seconds, got 0");
    expect(() => parseCli(["--interval", "soon"])).toThrow("--interval must be a positive number of seconds");
    expect(() => parseCli(["--threshold-bps=-1"])).toThrow("--threshold-bps must be a non-negative number, got -1");
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
});
