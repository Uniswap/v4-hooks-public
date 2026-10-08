import { afterEach, expect, mock, spyOn, test } from "bun:test";
import { fetchUsdPrices } from "../src/prices";

const NVDA = "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC";
const QQQ = "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68";

const stubFetch = (body: unknown) => spyOn(globalThis, "fetch").mockResolvedValue(Response.json(body));
afterEach(() => mock.restore());

test("posts the chain-scoped token list and keys spotUsd by lowercase address", async () => {
  const fetchSpy = stubFetch({
    tokens: [
      { address: NVDA.toLowerCase(), price: { spotUsd: 231.5 } },
      { address: QQQ, price: { spotUsd: 748.6 } },
    ],
  });
  expect(await fetchUsdPrices([NVDA, QQQ])).toEqual({ [NVDA.toLowerCase()]: 231.5, [QQQ.toLowerCase()]: 748.6 });
  const [url, init] = fetchSpy.mock.calls[0]!;
  expect(url).toBe("https://entry-gateway.backend-prod.api.uniswap.org/data.v2.DataApiService/GetTokens");
  expect(init?.method).toBe("POST");
  expect(new Headers(init?.headers).get("content-type")).toBe("application/json");
  expect(JSON.parse(String(init?.body))).toEqual({
    tokens: [
      { chainId: 4663, address: NVDA },
      { chainId: 4663, address: QQQ },
    ],
  });
});

test("throws when a token comes back without a positive spotUsd", async () => {
  stubFetch({
    tokens: [
      { address: NVDA, price: { spotUsd: 231.5 } },
      { address: QQQ, price: {} },
    ],
  });
  await expect(fetchUsdPrices([NVDA, QQQ])).rejects.toThrow(QQQ);
});
