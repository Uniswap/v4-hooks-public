import type { Address } from "viem";
import { CHAIN_ID } from "./constituents";

const GET_TOKENS_URL = "https://entry-gateway.backend-prod.api.uniswap.org/data.v2.DataApiService/GetTokens";

/** USD prices keyed by lowercase address; read them with usdPrice. */
export type UsdPrices = Record<string, number>;

interface GetTokensResponse {
  tokens?: { address?: string; price?: { spotUsd?: number } }[];
}

/** The price of `address`; throws unless it is a finite positive number. */
export function usdPrice(prices: UsdPrices, address: string): number {
  const price = prices[address.toLowerCase()];
  if (price === undefined || !Number.isFinite(price) || price <= 0) {
    throw new Error(`no valid USD price for ${address} (got ${price})`);
  }
  return price;
}

/** USD spot prices from the data-api; throws unless every address gets a valid price. */
export async function fetchUsdPrices(addresses: readonly Address[]): Promise<UsdPrices> {
  const response = await fetch(GET_TOKENS_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ tokens: addresses.map((address) => ({ chainId: CHAIN_ID, address })) }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error(`GetTokens: HTTP ${response.status} ${await response.text()}`);
  const { tokens = [] } = (await response.json()) as GetTokensResponse;
  const prices: UsdPrices = {};
  for (const { address, price } of tokens) {
    if (address && price?.spotUsd !== undefined) prices[address.toLowerCase()] = price.spotUsd;
  }
  for (const address of addresses) usdPrice(prices, address);
  return prices;
}
