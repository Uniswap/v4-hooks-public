import { afterEach, describe, expect, mock, spyOn, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  decodeFunctionResult,
  encodeAbiParameters,
  getAddress,
  isAddress,
  keccak256,
  toFunctionSelector,
  type Hex,
} from "viem";
import { CONSTITUENTS, DYNAMIC_FEE_FLAG, INDEX_TOKEN } from "../src/constituents";
import {
  DEFAULT_ABI_DIR,
  DEFAULT_DEPLOYMENTS,
  DEFAULT_OUT,
  HOOK_FUNCTIONS,
  VAULT_FUNCTIONS,
  buildStateViewAbi,
  checkAbiHas,
  main,
  parseCli,
  poolIdOf,
  validateDeployments,
} from "../src/exportForWeb";
import { DEFAULT_DEPLOYMENTS as KEEPER_DEPLOYMENTS, parseDeployments } from "../src/keeper";

type Json = Record<string, unknown>;
type Raw = Json & { constituents: Json[] };

interface PoolRow {
  symbol: string;
  stock: string;
  currency0: string;
  currency1: string;
  tickSpacing: number;
  tickLower: number;
  tickUpper: number;
  targetBps: number;
}

let poolsRead: PoolRow[] | undefined;

/**
 * The ten real pools of out/pools.4663.json (tracked in git), read on first use so that a missing file fails the tests
 * that need it rather than the whole file. Their addresses, order and weights are fixed by constituents.ts. Their ticks
 * follow the prices the file was generated at and change whenever it is regenerated, so no test may hard-code one:
 * expectations are taken from these rows, or the test sets its own ticks.
 */
function loadPools(): PoolRow[] {
  poolsRead ??= (
    JSON.parse(readFileSync(join(import.meta.dir, "../out/pools.4663.json"), "utf8")) as { pools: PoolRow[] }
  ).pools;
  return poolsRead;
}

const ZERO = "0x0000000000000000000000000000000000000000";
const HOOK = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd";
const OTHER_HOOK = "0xfeedfeedfeedfeedfeedfeedfeedfeedfeedfeed";
const VAULT = "0x1234567890abcdef1234567890abcdef12345678";
const POSITION_MANAGER = "0x58daec3116aae6d93017baaea7749052e8a04fa7";
const POOL_MANAGER = "0x8366a39cc670b4001a1121b8f6a443a643e40951";
const STATE_VIEW = "0xf3334192d15450cdd385c8b70e03f9a6bd9e673b";

/** The key order of the page's deployments.json. */
const BUNDLE_KEYS = [
  "chainId",
  "hook",
  "vault",
  "indexToken",
  "positionManager",
  "poolManager",
  "stateView",
  "constituents",
];
const CONSTITUENT_KEYS = [
  "symbol",
  "stock",
  "poolId",
  "currency0",
  "currency1",
  "tickSpacing",
  "tickLower",
  "tickUpper",
  "targetBps",
];

/** The page's abi/StateView.json (apps/web/src/pages/IndexVault/data/abi), byte for byte. */
const STATE_VIEW_JSON = `[
  {
    "name": "getSlot0",
    "type": "function",
    "stateMutability": "view",
    "inputs": [
      {
        "type": "bytes32",
        "name": "poolId"
      }
    ],
    "outputs": [
      {
        "type": "uint160",
        "name": "sqrtPriceX96"
      },
      {
        "type": "int24",
        "name": "tick"
      },
      {
        "type": "uint24",
        "name": "protocolFee"
      },
      {
        "type": "uint24",
        "name": "lpFee"
      }
    ]
  }
]
`;

/**
 * v4's PoolId of a dynamic-fee pool, keccak256(abi.encode(PoolKey)). The fixture's ids come from this, written out with
 * viem here rather than taken from the code under test.
 */
const poolIdFor = (currency0: string, currency1: string, tickSpacing: number, hook: string): Hex =>
  keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
      [currency0 as Hex, currency1 as Hex, DYNAMIC_FEE_FLAG, tickSpacing, hook as Hex],
    ),
  );

/**
 * A valid deployments file the way forge writes it (keys alphabetical, not in the page's order): the ten real pools,
 * their ids computed for the fixture's hook, and a made-up hook and vault.
 */
function rawDeployments(): Raw {
  return {
    chainId: 4663,
    constituents: loadPools().map((p) => ({
      currency0: p.currency0,
      currency1: p.currency1,
      poolId: poolIdFor(p.currency0, p.currency1, p.tickSpacing, HOOK),
      stock: p.stock,
      symbol: p.symbol,
      targetBps: p.targetBps,
      tickLower: p.tickLower,
      tickSpacing: p.tickSpacing,
      tickUpper: p.tickUpper,
    })),
    hook: HOOK,
    indexToken: INDEX_TOKEN,
    poolManager: POOL_MANAGER,
    positionManager: POSITION_MANAGER,
    stateView: STATE_VIEW,
    vault: VAULT,
  };
}

/** What the page should read for `raw`: the same values with the keys in the page's order, written out by hand. */
const pageShape = (raw: Raw) => ({
  chainId: raw.chainId,
  hook: raw.hook,
  vault: raw.vault,
  indexToken: raw.indexToken,
  positionManager: raw.positionManager,
  poolManager: raw.poolManager,
  stateView: raw.stateView,
  constituents: raw.constituents.map((c) => ({
    symbol: c.symbol,
    stock: c.stock,
    poolId: c.poolId,
    currency0: c.currency0,
    currency1: c.currency1,
    tickSpacing: c.tickSpacing,
    tickLower: c.tickLower,
    tickUpper: c.tickUpper,
    targetBps: c.targetBps,
  })),
});

const pool = (raw: Raw, symbol: string): Json => raw.constituents.find((c) => c.symbol === symbol)!;
const stockOf = (symbol: string): string => loadPools().find((p) => p.symbol === symbol)!.stock;

/** The message of the error `run` throws; fails the test if it does not throw. */
function rejection(run: () => unknown): string {
  try {
    run();
  } catch (error) {
    return (error as Error).message;
  }
  throw new Error("expected the call to throw");
}

const ADDRESS_FIELDS = ["hook", "vault", "indexToken", "positionManager", "poolManager", "stateView"];

/** `address` with the case of one letter flipped from its EIP-55 form: mixed case, and not the checksum. */
function wrongChecksum(address: string): string {
  const good = getAddress(address);
  for (let i = 2; i < good.length; i++) {
    const letter = good[i]!;
    if (!/[a-fA-F]/.test(letter)) continue;
    const flipped =
      good.slice(0, i) +
      (letter === letter.toUpperCase() ? letter.toLowerCase() : letter.toUpperCase()) +
      good.slice(i + 1);
    if (flipped !== flipped.toLowerCase() && !isAddress(flipped)) return flipped;
  }
  throw new Error(`no wrong-checksum variant of ${address}`);
}

describe("validateDeployments", () => {
  test("accepts the ten real pools and returns the page's key order, whatever order the deploy script wrote", () => {
    const raw = rawDeployments();
    expect(Object.keys(raw)).not.toEqual(BUNDLE_KEYS);
    expect(Object.keys(raw.constituents[0]!)).not.toEqual(CONSTITUENT_KEYS);
    const bundle = validateDeployments(raw);
    expect(Object.keys(bundle)).toEqual(BUNDLE_KEYS);
    expect(bundle.constituents).toHaveLength(10);
    for (const constituent of bundle.constituents) expect(Object.keys(constituent)).toEqual(CONSTITUENT_KEYS);
  });

  test("keeps every value as written (checksummed addresses, negative ticks) and drops unknown keys", () => {
    const raw = rawDeployments();
    raw.deployedAt = "yesterday";
    const nvda = pool(raw, "NVDA");
    nvda.note = "not part of the page's schema";
    // negative multiples of the spacing, whatever ticks the pools file was generated with
    [nvda.tickLower, nvda.tickUpper] = [-14010, -9540];
    const bundle = validateDeployments(raw);
    expect<unknown>(bundle).toEqual(pageShape(raw));
    expect(bundle).not.toHaveProperty("deployedAt");
    expect(bundle.constituents[0]).not.toHaveProperty("note");
    expect(bundle.indexToken).toBe(INDEX_TOKEN);
    expect(bundle.constituents[0]).toMatchObject({ tickLower: -14010, tickUpper: -9540 });
  });

  test("accepts targetBps that sum to 2 off 10000 in either direction", () => {
    for (const delta of [2, -2]) {
      const raw = rawDeployments();
      pool(raw, "NVDA").targetBps = (pool(raw, "NVDA").targetBps as number) + delta;
      expect(() => validateDeployments(raw)).not.toThrow();
    }
  });

  test("accepts every address checksummed or all-lowercase", () => {
    for (const form of [(address: string) => getAddress(address), (address: string) => address.toLowerCase()]) {
      const raw = rawDeployments();
      for (const field of ADDRESS_FIELDS) raw[field] = form(raw[field] as string);
      for (const c of raw.constituents) {
        for (const field of ["stock", "currency0", "currency1"]) c[field] = form(c[field] as string);
      }
      expect(() => validateDeployments(raw)).not.toThrow();
    }
  });

  test("accepts a poolId in uppercase hex and keeps it as written", () => {
    const raw = rawDeployments();
    const nvda = pool(raw, "NVDA");
    const shouting = `0x${(nvda.poolId as string).slice(2).toUpperCase()}`;
    expect(shouting).not.toBe(nvda.poolId);
    nvda.poolId = shouting;
    expect(validateDeployments(raw).constituents[0]!.poolId).toBe(shouting);
  });

  test("compares addresses case-insensitively and keeps them as written", () => {
    const raw = rawDeployments();
    raw.indexToken = INDEX_TOKEN.toLowerCase();
    pool(raw, "NVDA").stock = stockOf("NVDA").toLowerCase();
    const bundle = validateDeployments(raw);
    expect(bundle.indexToken).toBe(INDEX_TOKEN.toLowerCase());
    expect(bundle.constituents[0]!.stock).toBe(stockOf("NVDA").toLowerCase());
    expect(bundle.constituents[0]!.currency0).toBe(stockOf("NVDA"));
  });

  test("rejects input that is not a JSON object", () => {
    for (const raw of [null, [], "4663", 4663]) {
      expect(rejection(() => validateDeployments(raw))).toBe("deployments: not a JSON object");
    }
  });

  for (const field of ADDRESS_FIELDS) {
    test(`rejects a ${field} that is not 0x plus 40 hex digits`, () => {
      for (const bad of ["0x1234", `0x${"g".repeat(40)}`, `0x${"1".repeat(41)}`, 123, undefined]) {
        const raw = rawDeployments();
        raw[field] = bad;
        expect(rejection(() => validateDeployments(raw))).toStartWith(
          `deployments: ${field} must be 0x plus 40 hex digits, got `,
        );
      }
    });
  }

  for (const field of ADDRESS_FIELDS) {
    test(`rejects a ${field} in mixed case that is not its EIP-55 checksum`, () => {
      const raw = rawDeployments();
      const good = getAddress(raw[field] as string);
      const bad = wrongChecksum(good);
      raw[field] = bad;
      expect(rejection(() => validateDeployments(raw))).toBe(
        `deployments: ${field} has a wrong EIP-55 checksum, got ${bad}, expected ${good}`,
      );
    });
  }

  for (const field of ["stock", "currency0", "currency1"]) {
    test(`rejects a constituent ${field} in mixed case that is not its EIP-55 checksum`, () => {
      const raw = rawDeployments();
      const msft = pool(raw, "MSFT");
      const good = getAddress(msft[field] as string);
      const bad = wrongChecksum(good);
      msft[field] = bad;
      expect(rejection(() => validateDeployments(raw))).toBe(
        `deployments: constituents[2] (MSFT).${field} has a wrong EIP-55 checksum, got ${bad}, expected ${good}`,
      );
    });
  }

  // [name, break one thing in a valid file, the one line that must say so]
  const rejected: [string, (raw: Raw) => void, RegExp][] = [
    ["a different chain", (r) => void (r.chainId = 1), /^deployments: chainId is 1, expected 4663$/],
    ["a missing chainId", (r) => void delete r.chainId, /^deployments: chainId is undefined, expected 4663$/],
    ["the zero hook", (r) => void (r.hook = ZERO), /^deployments: hook is the zero address$/],
    ["the zero vault", (r) => void (r.vault = ZERO), /^deployments: vault is the zero address$/],
    [
      "an indexToken that is not QQQ",
      (r) => void (r.indexToken = stockOf("AAPL")),
      new RegExp(`^deployments: indexToken is 0x\\w+, expected ${INDEX_TOKEN}$`),
    ],
    [
      "a constituent stock that is not an address",
      (r) => void (pool(r, "AAPL").stock = "0x1234"),
      /^deployments: constituents\[1\] \(AAPL\)\.stock must be 0x plus 40 hex digits, got "0x1234"$/,
    ],
    [
      "a constituent currency0 that is not an address",
      (r) => void (pool(r, "MSFT").currency0 = "0x1234"),
      /^deployments: constituents\[2\] \(MSFT\)\.currency0 must be 0x plus 40 hex digits, got "0x1234"$/,
    ],
    [
      "a constituent currency1 that is not an address",
      (r) => void (pool(r, "MSFT").currency1 = `0x${"z".repeat(40)}`),
      /^deployments: constituents\[2\] \(MSFT\)\.currency1 must be 0x plus 40 hex digits/,
    ],
    [
      "a poolId that is too short",
      (r) => void (pool(r, "GOOGL").poolId = "0x1234"),
      /^deployments: constituents\[3\] \(GOOGL\)\.poolId must be 0x plus 64 hex digits, got "0x1234"$/,
    ],
    [
      "a poolId of 64 non-hex characters",
      (r) => void (pool(r, "NVDA").poolId = `0x${"zz".repeat(32)}`),
      /\(NVDA\)\.poolId must be 0x plus 64 hex digits/,
    ],
    [
      "a poolId so long that the message cuts it short",
      (r) => void (pool(r, "NVDA").poolId = `0x${"a".repeat(200)}`),
      /\(NVDA\)\.poolId must be 0x plus 64 hex digits, got "0xa{77}$/,
    ],
    [
      "an address where the poolId should be",
      (r) => void (pool(r, "NVDA").poolId = HOOK),
      /\(NVDA\)\.poolId must be 0x plus 64 hex digits/,
    ],
    [
      "a missing poolId",
      (r) => void delete pool(r, "NVDA").poolId,
      /\(NVDA\)\.poolId must be 0x plus 64 hex digits, got undefined$/,
    ],
    [
      "currencies in the wrong order",
      (r) => {
        const c = pool(r, "NVDA");
        [c.currency0, c.currency1] = [c.currency1, c.currency0];
      },
      /^deployments: constituents\[0\] \(NVDA\): currency0 0x\w+ must sort below currency1 0x\w+$/,
    ],
    [
      "equal currencies",
      (r) => {
        const c = pool(r, "NVDA");
        [c.currency0, c.currency1, c.stock] = [INDEX_TOKEN, INDEX_TOKEN, INDEX_TOKEN];
      },
      /^deployments: constituents\[0\] \(NVDA\): currency0 0x\w+ must sort below currency1 0x\w+$/,
    ],
    [
      "a pool without the index token",
      (r) => void (pool(r, "NVDA").currency1 = stockOf("MSFT")),
      /^deployments: constituents\[0\] \(NVDA\): neither currency is the index token 0x\w+$/,
    ],
    [
      "a stock that is not the pool's other currency",
      (r) => void (pool(r, "NVDA").stock = stockOf("AAPL")),
      /^deployments: constituents\[0\] \(NVDA\): stock 0x\w+ is not the pool's non-index currency 0x\w+$/,
    ],
    [
      "a tickLower off the spacing",
      (r) => void (pool(r, "NVDA").tickLower = -14005),
      /^deployments: constituents\[0\] \(NVDA\): tickLower -14005 is not a multiple of tickSpacing 10$/,
    ],
    [
      "a negative tickUpper off the spacing",
      (r) => void (pool(r, "AAPL").tickUpper = -6431),
      /^deployments: constituents\[1\] \(AAPL\): tickUpper -6431 is not a multiple of tickSpacing 10$/,
    ],
    [
      "equal ticks",
      (r) => {
        const c = pool(r, "MSFT");
        [c.tickLower, c.tickUpper] = [600, 600];
      },
      /^deployments: constituents\[2\] \(MSFT\): tickLower 600 must be below tickUpper 600$/,
    ],
    [
      "ticks the wrong way round",
      (r) => {
        const c = pool(r, "MSFT");
        [c.tickLower, c.tickUpper] = [600, -400];
      },
      /^deployments: constituents\[2\] \(MSFT\): tickLower 600 must be below tickUpper -400$/,
    ],
    [
      "a zero tickSpacing",
      (r) => void (pool(r, "NVDA").tickSpacing = 0),
      /\(NVDA\)\.tickSpacing must be an integer >= 1, got 0$/,
    ],
    [
      "a tickLower that is not an integer",
      (r) => void (pool(r, "NVDA").tickLower = 1.5),
      /\(NVDA\)\.tickLower must be an integer, got 1\.5$/,
    ],
    [
      "a tickUpper that is not an integer",
      (r) => void (pool(r, "NVDA").tickUpper = 1.5),
      /\(NVDA\)\.tickUpper must be an integer, got 1\.5$/,
    ],
    [
      "targetBps as a string",
      (r) => void (pool(r, "NVDA").targetBps = "1719"),
      /\(NVDA\)\.targetBps must be an integer >= 0, got "1719"$/,
    ],
    [
      "a targetBps sum 3 over 10000",
      (r) => void (pool(r, "NVDA").targetBps = 1722),
      /^deployments: targetBps sum to 10003, expected 10000 \+\/- 2$/,
    ],
    [
      "a targetBps sum 3 under 10000",
      (r) => void (pool(r, "NVDA").targetBps = 1716),
      /^deployments: targetBps sum to 9997, expected 10000 \+\/- 2$/,
    ],
    [
      "9 constituents",
      (r) => void r.constituents.pop(),
      /^deployments: constituents must be an array of 10 entries, got 9 entries$/,
    ],
    [
      "11 constituents",
      (r) => void r.constituents.push({ ...r.constituents[0] }),
      /^deployments: constituents must be an array of 10 entries, got 11 entries$/,
    ],
    [
      "constituents that is not an array",
      (r) => void (r.constituents = {} as unknown as Json[]),
      /^deployments: constituents must be an array of 10 entries, got \{\}$/,
    ],
    [
      "an empty symbol",
      (r) => void (pool(r, "NVDA").symbol = ""),
      /^deployments: constituents\[0\]\.symbol must be a non-empty string$/,
    ],
    [
      "a constituent that is not an object",
      (r) => void (r.constituents[3] = "GOOGL" as unknown as Json),
      /^deployments: constituents\[3\] must be an object, got "GOOGL"$/,
    ],
  ];
  for (const [name, breakIt, message] of rejected) {
    test(`rejects ${name} with one line`, () => {
      const raw = rawDeployments();
      breakIt(raw);
      const error = rejection(() => validateDeployments(raw));
      expect(error).toMatch(message);
      expect(error).not.toContain("\n");
    });
  }

  test("rejects a poolId that is not the id of its pool key, naming the id it should have", () => {
    const [nvda, aapl] = rawDeployments().constituents as [Json, Json];
    const [currency0, currency1, spacing] = [
      nvda.currency0 as string,
      nvda.currency1 as string,
      nvda.tickSpacing as number,
    ];
    const expected = poolIdFor(currency0, currency1, spacing, HOOK);
    const stale = [
      poolIdFor(currency0, currency1, spacing, OTHER_HOOK), // made for another hook
      poolIdFor(currency0, currency1, spacing * 6, HOOK), // made for another tickSpacing
      poolIdFor(currency1, currency0, spacing, HOOK), // made with the currencies swapped
      aapl.poolId as string, // another pool's
    ];
    for (const id of stale) {
      const raw = rawDeployments();
      raw.constituents[0]!.poolId = id;
      expect(rejection(() => validateDeployments(raw))).toBe(
        `deployments: constituents[0] (NVDA): poolId ${id} is not the id of its pool key, expected ${expected}`,
      );
    }
  });

  test("derives the expected id from the entry's own tickSpacing and from the bundle's hook", () => {
    const respaced = rawDeployments();
    const nvda = pool(respaced, "NVDA");
    nvda.tickSpacing = 1; // the ticks stay multiples of it; the id was made for the old spacing
    expect(rejection(() => validateDeployments(respaced))).toBe(
      `deployments: constituents[0] (NVDA): poolId ${nvda.poolId} is not the id of its pool key, ` +
        `expected ${poolIdFor(nvda.currency0 as string, nvda.currency1 as string, 1, HOOK)}`,
    );

    const rehooked = rawDeployments();
    rehooked.hook = OTHER_HOOK; // every id was made for HOOK
    const first = rehooked.constituents[0]!;
    expect(rejection(() => validateDeployments(rehooked))).toBe(
      `deployments: constituents[0] (NVDA): poolId ${first.poolId} is not the id of its pool key, ` +
        `expected ${poolIdFor(
          first.currency0 as string,
          first.currency1 as string,
          first.tickSpacing as number,
          OTHER_HOOK,
        )}`,
    );
  });

  test("rejects a pool listed twice, whatever the case of its pool id", () => {
    const copied = rawDeployments();
    copied.constituents[3] = { ...copied.constituents[0] };
    const id = copied.constituents[0]!.poolId as string;
    expect(rejection(() => validateDeployments(copied))).toBe(
      `deployments: constituents[3] (NVDA): poolId ${id} duplicates constituents[0] (NVDA)`,
    );

    const shouting = `0x${id.slice(2).toUpperCase()}`;
    const recased = rawDeployments();
    recased.constituents[3] = { ...recased.constituents[0], poolId: shouting };
    expect(rejection(() => validateDeployments(recased))).toBe(
      `deployments: constituents[3] (NVDA): poolId ${shouting} duplicates constituents[0] (NVDA)`,
    );
  });
});

const fn = (name: string) => ({ type: "function", name, inputs: [], outputs: [], stateMutability: "view" });

/** An ABI shaped like forge inspect --json: nameless constructor, fallback and receive items around the functions. */
const abiWith = (names: readonly string[]): Json[] => [
  { type: "constructor", inputs: [], stateMutability: "nonpayable" },
  ...names.map(fn),
  { type: "event", name: "Deposit", inputs: [], anonymous: false },
  { type: "error", name: "ZeroShares", inputs: [] },
  { type: "fallback", stateMutability: "payable" },
  { type: "receive", stateMutability: "payable" },
];

describe("checkAbiHas", () => {
  test("the required functions are the ones the page calls on the vault and the hook", () => {
    expect([...VAULT_FUNCTIONS]).toEqual([
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
    ]);
    expect([...HOOK_FUNCTIONS]).toEqual(["feeConfig", "feeState", "getFee", "batchUpdateFeeConfig"]);
  });

  test("accepts an ABI with every required function, nameless constructor, fallback and receive included", () => {
    expect(() => checkAbiHas(abiWith(VAULT_FUNCTIONS), VAULT_FUNCTIONS, "IndexLpVault ABI")).not.toThrow();
    expect(() => checkAbiHas(abiWith(HOOK_FUNCTIONS), HOOK_FUNCTIONS, "StablePairHook ABI")).not.toThrow();
  });

  test("names the missing function when any one required function is absent", () => {
    for (const name of VAULT_FUNCTIONS) {
      const abi = abiWith(VAULT_FUNCTIONS.filter((n) => n !== name));
      expect(rejection(() => checkAbiHas(abi, VAULT_FUNCTIONS, "IndexLpVault ABI"))).toBe(
        `IndexLpVault ABI is missing function(s): ${name}`,
      );
    }
    for (const name of HOOK_FUNCTIONS) {
      const abi = abiWith(HOOK_FUNCTIONS.filter((n) => n !== name));
      expect(rejection(() => checkAbiHas(abi, HOOK_FUNCTIONS, "StablePairHook ABI"))).toBe(
        `StablePairHook ABI is missing function(s): ${name}`,
      );
    }
  });

  test("lists every missing function on one line", () => {
    const abi = abiWith(VAULT_FUNCTIONS.filter((n) => n !== "holdings" && n !== "redeem"));
    expect(rejection(() => checkAbiHas(abi, VAULT_FUNCTIONS, "IndexLpVault ABI"))).toBe(
      "IndexLpVault ABI is missing function(s): holdings, redeem",
    );
  });

  test("an event or error of the same name is not the function", () => {
    const abi = [...abiWith(VAULT_FUNCTIONS.filter((n) => n !== "deposit")), { type: "event", name: "deposit" }];
    expect(rejection(() => checkAbiHas(abi, VAULT_FUNCTIONS, "IndexLpVault ABI"))).toContain("function(s): deposit");
    const withError = [...abiWith(HOOK_FUNCTIONS.filter((n) => n !== "getFee")), { type: "error", name: "getFee" }];
    expect(rejection(() => checkAbiHas(withError, HOOK_FUNCTIONS, "StablePairHook ABI"))).toContain(
      "function(s): getFee",
    );
  });

  test("rejects anything that is not a JSON array of ABI items", () => {
    for (const abi of [{}, { abi: "[]" }, "[]", null, 7]) {
      expect(rejection(() => checkAbiHas(abi, HOOK_FUNCTIONS, "StablePairHook ABI"))).toBe(
        "StablePairHook ABI is not a JSON array of ABI items",
      );
    }
  });

  test("calls a forge artifact by its name, and ends the message with the hint when given one", () => {
    const artifact = { abi: abiWith(HOOK_FUNCTIONS), bytecode: { object: "0x" } };
    expect(rejection(() => checkAbiHas(artifact, HOOK_FUNCTIONS, "StablePairHook ABI"))).toBe(
      "StablePairHook ABI is a forge artifact, not a JSON array of ABI items",
    );
    expect(rejection(() => checkAbiHas(artifact, HOOK_FUNCTIONS, "StablePairHook ABI", "export it properly"))).toBe(
      "StablePairHook ABI is a forge artifact, not a JSON array of ABI items; export it properly",
    );
    expect(rejection(() => checkAbiHas({}, HOOK_FUNCTIONS, "StablePairHook ABI", "export it properly"))).toBe(
      "StablePairHook ABI is not a JSON array of ABI items; export it properly",
    );
  });

  test("rejects an item that is not an ABI item and says which", () => {
    const items: [unknown, string][] = [
      [{ foo: 1 }, '{"foo":1}'],
      ["feeConfig", '"feeConfig"'],
      [{ type: "function", inputs: [] }, '{"type":"function","inputs":[]}'],
      [{ type: "struct", name: "S" }, '{"type":"struct","name":"S"}'],
      [null, "null"],
    ];
    for (const [item, shown] of items) {
      const abi = [...abiWith(HOOK_FUNCTIONS), item];
      expect(rejection(() => checkAbiHas(abi, HOOK_FUNCTIONS, "StablePairHook ABI"))).toBe(
        `StablePairHook ABI item ${abi.length - 1} is not an ABI item, got ${shown}`,
      );
    }
  });
});

describe("buildStateViewAbi", () => {
  test("is exactly getSlot0(bytes32 poolId) view with the four named outputs", () => {
    const abi = buildStateViewAbi();
    expect(abi).toHaveLength(1);
    expect(abi[0]).toEqual({
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
    });
  });

  test("serializes to the page's existing StateView.json, byte for byte", () => {
    expect(`${JSON.stringify(buildStateViewAbi(), null, 2)}\n`).toBe(STATE_VIEW_JSON);
  });

  test("has the selector of getSlot0(bytes32) and decodes a slot0 result, negative tick included", () => {
    const abi = buildStateViewAbi();
    expect(toFunctionSelector(abi[0] as Parameters<typeof toFunctionSelector>[0])).toBe(
      toFunctionSelector("getSlot0(bytes32)"),
    );
    const sqrtPriceX96 = 43976376245197058051810525184n;
    const data = encodeAbiParameters(
      [{ type: "uint160" }, { type: "int24" }, { type: "uint24" }, { type: "uint24" }],
      [sqrtPriceX96, -11775, 0, 8388608],
    );
    expect(decodeFunctionResult({ abi, functionName: "getSlot0", data })).toEqual([sqrtPriceX96, -11775, 0, 8388608]);
  });
});

const roots: string[] = [];
afterEach(() => {
  mock.restore();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

/**
 * A temp directory laid out like tooling/: the deployments file, and ABIs in forge's item shape but minified, so the
 * export has to rewrite them in the page's layout. `out` is where the export should write; it is not created.
 */
function workspace(
  options: { deployments?: Raw; vaultFunctions?: readonly string[]; hookFunctions?: readonly string[] } = {},
) {
  const root = mkdtempSync(join(tmpdir(), "export-for-web-"));
  roots.push(root);
  const abi = join(root, "deployments", "abi");
  mkdirSync(abi, { recursive: true });
  const deployments = join(root, "deployments", "4663.json");
  writeFileSync(deployments, JSON.stringify(options.deployments ?? rawDeployments(), null, 2));
  writeFileSync(join(abi, "IndexLpVault.json"), JSON.stringify(abiWith(options.vaultFunctions ?? VAULT_FUNCTIONS)));
  writeFileSync(join(abi, "StablePairHook.json"), JSON.stringify(abiWith(options.hookFunctions ?? HOOK_FUNCTIONS)));
  const out = join(root, "out", "web");
  return { deployments, abi, out, args: ["--deployments", deployments, "--abi", abi, "--out", out] };
}

/** Runs main with console output captured. */
function run(args: string[]): { code: number; stdout: string[]; stderr: string[] } {
  const log = spyOn(console, "log").mockImplementation(() => {});
  const error = spyOn(console, "error").mockImplementation(() => {});
  try {
    const code = main(args);
    return {
      code,
      stdout: log.mock.calls.map((call) => String(call[0])),
      stderr: error.mock.calls.map((call) => String(call[0])),
    };
  } finally {
    log.mockRestore();
    error.mockRestore();
  }
}

const OUTPUTS = ["deployments.json", "abi/IndexLpVault.json", "abi/StablePairHook.json", "abi/StateView.json"];

describe("export end to end", () => {
  test("writes the four files the page reads in the page's layout and prints them", () => {
    const ws = workspace();
    const { code, stdout, stderr } = run(["--deployments", ws.deployments, "--abi", ws.abi, "--out", `${ws.out}/`]);
    expect({ code, stderr }).toEqual({ code: 0, stderr: [] });
    const paths = OUTPUTS.map((file) => join(ws.out, file));
    expect(stdout).toEqual(paths.map((path) => `wrote ${path}`));

    const [deployments, vault, hook, stateView] = paths.map((path) => readFileSync(path, "utf8"));
    expect(deployments).toBe(`${JSON.stringify(pageShape(rawDeployments()), null, 2)}\n`);
    expect(vault).toBe(`${JSON.stringify(abiWith(VAULT_FUNCTIONS), null, 2)}\n`);
    expect(hook).toBe(`${JSON.stringify(abiWith(HOOK_FUNCTIONS), null, 2)}\n`);
    expect(stateView).toBe(STATE_VIEW_JSON);
  });

  test("deployments.json has the page's layout: two-space indent, the page's key order, a trailing newline", () => {
    const ws = workspace();
    expect(run(ws.args).code).toBe(0);
    const text = readFileSync(join(ws.out, "deployments.json"), "utf8");
    const first = rawDeployments().constituents[0]!;
    expect(text.split("\n").slice(0, 21)).toEqual([
      "{",
      '  "chainId": 4663,',
      `  "hook": "${HOOK}",`,
      `  "vault": "${VAULT}",`,
      `  "indexToken": "${INDEX_TOKEN}",`,
      `  "positionManager": "${POSITION_MANAGER}",`,
      `  "poolManager": "${POOL_MANAGER}",`,
      `  "stateView": "${STATE_VIEW}",`,
      '  "constituents": [',
      "    {",
      `      "symbol": "${first.symbol}",`,
      `      "stock": "${first.stock}",`,
      `      "poolId": "${first.poolId}",`,
      `      "currency0": "${first.currency0}",`,
      `      "currency1": "${first.currency1}",`,
      `      "tickSpacing": ${first.tickSpacing},`,
      `      "tickLower": ${first.tickLower},`,
      `      "tickUpper": ${first.tickUpper},`,
      `      "targetBps": ${first.targetBps}`,
      "    },",
      "    {",
    ]);
    expect(text.endsWith("    }\n  ]\n}\n")).toBe(true);
  });

  test("a rerun rewrites byte-identical files", () => {
    const ws = workspace();
    expect(run(ws.args).code).toBe(0);
    const first = OUTPUTS.map((file) => readFileSync(join(ws.out, file), "utf8"));
    expect(run(ws.args).code).toBe(0);
    expect(OUTPUTS.map((file) => readFileSync(join(ws.out, file), "utf8"))).toEqual(first);
  });

  test("a broken deployments file fails with one line and writes nothing", () => {
    const raw = rawDeployments();
    raw.chainId = 1;
    const ws = workspace({ deployments: raw });
    expect(run(ws.args)).toEqual({
      code: 1,
      stdout: [],
      stderr: ["exportForWeb: deployments: chainId is 1, expected 4663"],
    });
    expect(existsSync(ws.out)).toBe(false);
  });

  test("a vault ABI without a function the page calls fails before even deployments.json is written", () => {
    const ws = workspace({ vaultFunctions: VAULT_FUNCTIONS.filter((name) => name !== "holdings") });
    expect(run(ws.args)).toEqual({
      code: 1,
      stdout: [],
      stderr: [
        `exportForWeb: IndexLpVault ABI (${join(ws.abi, "IndexLpVault.json")}) is missing function(s): holdings`,
      ],
    });
    expect(existsSync(ws.out)).toBe(false);
  });

  test("a hook ABI without a function the keeper or page calls fails the same way", () => {
    const ws = workspace({ hookFunctions: HOOK_FUNCTIONS.filter((name) => name !== "getFee") });
    expect(run(ws.args)).toEqual({
      code: 1,
      stdout: [],
      stderr: [
        `exportForWeb: StablePairHook ABI (${join(ws.abi, "StablePairHook.json")}) is missing function(s): getFee`,
      ],
    });
    expect(existsSync(ws.out)).toBe(false);
  });

  test("a failure stays one line even when a value in the file carries a newline", () => {
    const raw = rawDeployments();
    const nvda = pool(raw, "NVDA");
    nvda.symbol = "NV\nDA";
    nvda.stock = "0x1";
    expect(run(workspace({ deployments: raw }).args).stderr).toEqual([
      'exportForWeb: deployments: constituents[0] (NV DA).stock must be 0x plus 40 hex digits, got "0x1"',
    ]);
  });

  test("a missing deployments file or ABI file says what to run", () => {
    const ws = workspace();
    rmSync(ws.deployments);
    expect(run(ws.args).stderr).toEqual([
      `exportForWeb: no deployments file at ${ws.deployments}; ` +
        "run the deploy script first, or pass --deployments <file>",
    ]);
    const other = workspace();
    rmSync(join(other.abi, "StablePairHook.json"));
    expect(run(other.args).stderr).toEqual([
      `exportForWeb: no StablePairHook ABI at ${join(other.abi, "StablePairHook.json")}; ` +
        "export it with forge inspect <Contract> abi --json, or pass --abi <dir>",
    ]);
    expect(existsSync(ws.out) || existsSync(other.out)).toBe(false);
  });

  test("a directory in place of an input is reported as unreadable, not as bad JSON", () => {
    const ws = workspace();
    rmSync(ws.deployments);
    mkdirSync(ws.deployments);
    const deployments = run(ws.args);
    expect({ code: deployments.code, stdout: deployments.stdout }).toEqual({ code: 1, stdout: [] });
    expect(deployments.stderr).toHaveLength(1);
    expect(deployments.stderr[0]).toStartWith(
      `exportForWeb: cannot read deployments file at ${ws.deployments} (EISDIR`,
    );
    expect(deployments.stderr[0]).toEndWith("run the deploy script first, or pass --deployments <file>");
    expect(deployments.stderr[0]).not.toContain("not valid JSON");

    const other = workspace();
    const abiPath = join(other.abi, "IndexLpVault.json");
    rmSync(abiPath);
    mkdirSync(abiPath);
    const abi = run(other.args);
    expect(abi.stderr).toHaveLength(1);
    expect(abi.stderr[0]).toStartWith(`exportForWeb: cannot read IndexLpVault ABI at ${abiPath} (EISDIR`);
    expect(abi.stderr[0]).toEndWith("export it with forge inspect <Contract> abi --json, or pass --abi <dir>");
    expect(abi.stderr[0]).not.toContain("not valid JSON");
    expect(existsSync(ws.out) || existsSync(other.out)).toBe(false);
  });

  // root can read any file, so there is nothing for it to be refused
  test.skipIf(process.getuid?.() === 0)("a file that is not readable is reported as unreadable too", () => {
    const ws = workspace();
    chmodSync(ws.deployments, 0o000);
    const { code, stdout, stderr } = run(ws.args);
    expect({ code, stdout }).toEqual({ code: 1, stdout: [] });
    expect(stderr).toHaveLength(1);
    expect(stderr[0]).toStartWith(`exportForWeb: cannot read deployments file at ${ws.deployments} (EACCES`);
    expect(stderr[0]).not.toContain("not valid JSON");
    expect(existsSync(ws.out)).toBe(false);
  });

  test("a forge artifact (an object with an abi array) gets the same forge inspect --json hint as the table", () => {
    const ws = workspace();
    const path = join(ws.abi, "StablePairHook.json");
    writeFileSync(path, JSON.stringify({ abi: abiWith(HOOK_FUNCTIONS), bytecode: { object: "0x" } }));
    expect(run(ws.args)).toEqual({
      code: 1,
      stdout: [],
      stderr: [
        `exportForWeb: StablePairHook ABI (${path}) is a forge artifact, not a JSON array of ABI items; ` +
          "export it with forge inspect <Contract> abi --json, or pass --abi <dir>",
      ],
    });
    expect(existsSync(ws.out)).toBe(false);
  });

  test("an ABI file that is forge's table (inspect without --json) fails with a hint, not a stack", () => {
    const ws = workspace();
    const table = "╭-------------+------------╮\n| Type        | Signature  |\n+===========================+\n";
    writeFileSync(join(ws.abi, "IndexLpVault.json"), table);
    const { code, stdout, stderr } = run(ws.args);
    expect({ code, stdout }).toEqual({ code: 1, stdout: [] });
    expect(stderr).toHaveLength(1);
    expect(stderr[0]).toStartWith(
      `exportForWeb: IndexLpVault ABI at ${join(ws.abi, "IndexLpVault.json")} is not valid JSON (`,
    );
    expect(stderr[0]).toEndWith("export it with forge inspect <Contract> abi --json, or pass --abi <dir>");
    expect(stderr[0]).not.toContain("\n");
    expect(existsSync(ws.out)).toBe(false);
  });

  test("an unknown flag fails with one line", () => {
    const { code, stdout, stderr } = run(["--abis", "somewhere"]);
    expect({ code, stdout }).toEqual({ code: 1, stdout: [] });
    expect(stderr).toHaveLength(1);
    expect(stderr[0]).toStartWith("exportForWeb: Unknown option '--abis'");
  });

  test("the CLI prints the files and exits 0, and on a failed check exits 1 with one stderr line", () => {
    const cwd = join(import.meta.dir, "..");
    const ok = workspace();
    const success = Bun.spawnSync([process.execPath, "run", "src/exportForWeb.ts", ...ok.args], { cwd });
    expect(success.exitCode).toBe(0);
    expect(success.stderr.toString()).toBe("");
    expect(success.stdout.toString()).toBe(OUTPUTS.map((file) => `wrote ${join(ok.out, file)}\n`).join(""));
    expect(readFileSync(join(ok.out, "abi/StateView.json"), "utf8")).toBe(STATE_VIEW_JSON);

    const raw = rawDeployments();
    raw.chainId = 1;
    const bad = workspace({ deployments: raw });
    const failure = Bun.spawnSync([process.execPath, "run", "src/exportForWeb.ts", ...bad.args], { cwd });
    expect(failure.exitCode).toBe(1);
    expect(failure.stdout.toString()).toBe("");
    expect(failure.stderr.toString()).toBe("exportForWeb: deployments: chainId is 1, expected 4663\n");
    expect(existsSync(bad.out)).toBe(false);
  });
});

describe("poolIdOf", () => {
  // Two of the real pools at the hook live on chain 4663. Each id exists there (StateView.getSlot0 returns a non-zero
  // sqrtPriceX96) and equals Foundry's keccak of abi.encode(currency0, currency1, 8388608, 10, hook), so these pin the
  // formula against something other than a second copy of it.
  const LIVE_HOOK = "0xD5711B1F57e75B1c91c32AD96C4d4E5019D6Bcc0";
  const stock = (symbol: string) => CONSTITUENTS.find((c) => c.symbol === symbol)!.address;

  test("gives the ids of real pools on chain, with the stock as currency0 and as currency1", () => {
    expect(poolIdOf(stock("NVDA"), INDEX_TOKEN, 10, LIVE_HOOK)).toBe(
      "0xc7a754401be5e95905b290fd6a356c246fe0004643f36f18ddf9b38fa682d768",
    );
    expect(poolIdOf(INDEX_TOKEN, stock("MSFT"), 10, LIVE_HOOK)).toBe(
      "0x3340fa91eae89286403650775fa7c0e7ee794f691c495fbe1df1e470de524c5f",
    );
  });

  test("changes with every field of the pool key and not with the case of an address", () => {
    const [nvda, qqq] = [stock("NVDA"), INDEX_TOKEN];
    const id = poolIdOf(nvda, qqq, 10, LIVE_HOOK);
    const others = [
      poolIdOf(qqq, nvda, 10, LIVE_HOOK),
      poolIdOf(nvda, qqq, 60, LIVE_HOOK),
      poolIdOf(nvda, qqq, 10, HOOK),
    ];
    expect(new Set([id, ...others]).size).toBe(4);
    expect(poolIdOf(nvda.toLowerCase(), qqq.toLowerCase(), 10, LIVE_HOOK.toLowerCase())).toBe(id);
  });
});

describe("parseCli", () => {
  test("defaults to the documented paths under tooling/", () => {
    const tooling = join(import.meta.dir, "..");
    expect(DEFAULT_DEPLOYMENTS).toBe(join(tooling, "deployments", "4663.json"));
    expect(DEFAULT_ABI_DIR).toBe(join(tooling, "deployments", "abi"));
    expect(DEFAULT_OUT).toBe(join(tooling, "out", "web"));
    expect(parseCli([])).toEqual({ deployments: DEFAULT_DEPLOYMENTS, abiDir: DEFAULT_ABI_DIR, out: DEFAULT_OUT });
  });

  test("each flag replaces only its own path", () => {
    const defaults = { deployments: DEFAULT_DEPLOYMENTS, abiDir: DEFAULT_ABI_DIR, out: DEFAULT_OUT };
    expect(parseCli(["--deployments", "d.json"])).toEqual({ ...defaults, deployments: "d.json" });
    expect(parseCli(["--abi", "abis"])).toEqual({ ...defaults, abiDir: "abis" });
    expect(parseCli(["--out", "web/"])).toEqual({ ...defaults, out: "web/" });
    expect(parseCli(["--out", "web/", "--abi", "abis", "--deployments", "d.json"])).toEqual({
      deployments: "d.json",
      abiDir: "abis",
      out: "web/",
    });
  });

  test("rejects an unknown flag and a stray argument", () => {
    expect(() => parseCli(["--abis", "somewhere"])).toThrow("Unknown option '--abis'");
    expect(() => parseCli(["somewhere"])).toThrow();
  });
});

describe("agreement with the keeper", () => {
  test("the keeper's parseDeployments accepts the fixture the exporter accepts", () => {
    const raw = rawDeployments();
    expect(() => validateDeployments(raw)).not.toThrow();
    expect(parseDeployments(raw).pools).toHaveLength(10);
  });

  test("both read the same deployments file by default", () => {
    expect(DEFAULT_DEPLOYMENTS).toBe(KEEPER_DEPLOYMENTS);
  });
});
