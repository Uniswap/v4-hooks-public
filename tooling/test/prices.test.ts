import { afterEach, expect, mock, spyOn, test } from "bun:test";
import { fetchUsdPrices, usdPrice } from "../src/prices";

const NVDA = "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC";
const QQQ = "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68";

const stubFetch = (body: unknown, status = 200) =>
  spyOn(globalThis, "fetch").mockResolvedValue(Response.json(body, { status }));
afterEach(() => mock.restore());

test("posts the chain-scoped token list with a 10 s timeout and keys spotUsd by lowercase address", async () => {
  const fetchSpy = stubFetch({
    tokens: [
      { address: NVDA.toLowerCase(), price: { spotUsd: 231.5 } },
      { address: QQQ, price: { spotUsd: 748.6 } },
    ],
  });
  const timeoutSpy = spyOn(AbortSignal, "timeout");
  expect(await fetchUsdPrices([NVDA, QQQ])).toEqual({ [NVDA.toLowerCase()]: 231.5, [QQQ.toLowerCase()]: 748.6 });
  const [url, init] = fetchSpy.mock.calls[0]!;
  expect(url).toBe("https://entry-gateway.backend-prod.api.uniswap.org/data.v2.DataApiService/GetTokens");
  expect(init?.method).toBe("POST");
  expect(new Headers(init?.headers).get("content-type")).toBe("application/json");
  expect(timeoutSpy).toHaveBeenCalledWith(10_000);
  expect(timeoutSpy.mock.results[0]!.value).toBe(init?.signal);
  expect(JSON.parse(String(init?.body))).toEqual({
    tokens: [
      { chainId: 4663, address: NVDA },
      { chainId: 4663, address: QQQ },
    ],
  });
});

test("throws on a non-2xx response even when the body carries prices", async () => {
  stubFetch(
    {
      tokens: [
        { address: NVDA, price: { spotUsd: 231.5 } },
        { address: QQQ, price: { spotUsd: 748.6 } },
      ],
    },
    500,
  );
  await expect(fetchUsdPrices([NVDA, QQQ])).rejects.toThrow("GetTokens: HTTP 500");
});

test("throws when a token comes back without a spotUsd", async () => {
  stubFetch({
    tokens: [
      { address: NVDA, price: { spotUsd: 231.5 } },
      { address: QQQ, price: {} },
    ],
  });
  await expect(fetchUsdPrices([NVDA, QQQ])).rejects.toThrow(`no valid USD price for ${QQQ}`);
});

test("throws when a token comes back with a zero spotUsd", async () => {
  stubFetch({
    tokens: [
      { address: NVDA, price: { spotUsd: 231.5 } },
      { address: QQQ, price: { spotUsd: 0 } },
    ],
  });
  await expect(fetchUsdPrices([NVDA, QQQ])).rejects.toThrow(`no valid USD price for ${QQQ}`);
});

test("usdPrice reads by lowercase address and rejects missing, non-finite or non-positive prices", () => {
  expect(usdPrice({ [NVDA.toLowerCase()]: 231.5 }, NVDA)).toBe(231.5);
  for (const bad of [undefined, 0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
    const prices = bad === undefined ? {} : { [NVDA.toLowerCase()]: bad };
    expect(() => usdPrice(prices, NVDA)).toThrow(`no valid USD price for ${NVDA}`);
  }
});
