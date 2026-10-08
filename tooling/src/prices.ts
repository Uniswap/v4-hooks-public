import type { Address } from "viem";
import { CHAIN_ID } from "./constituents";

const GET_TOKENS_URL = "https://entry-gateway.backend-prod.api.uniswap.org/data.v2.DataApiService/GetTokens";

interface GetTokensResponse {
  tokens?: { address?: string; price?: { spotUsd?: number } }[];
}

/** USD spot prices from the data-api, keyed by lowercase address; throws unless every address has a positive price. */
export async function fetchUsdPrices(addresses: readonly Address[]): Promise<Record<string, number>> {
  const response = await fetch(GET_TOKENS_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ tokens: addresses.map((address) => ({ chainId: CHAIN_ID, address })) }),
  });
  if (!response.ok) throw new Error(`GetTokens: HTTP ${response.status} ${await response.text()}`);
  const { tokens = [] } = (await response.json()) as GetTokensResponse;
  const prices: Record<string, number> = {};
  for (const { address, price } of tokens) {
    const spotUsd = price?.spotUsd;
    if (address && typeof spotUsd === "number" && spotUsd > 0) prices[address.toLowerCase()] = spotUsd;
  }
  const missing = addresses.filter((address) => prices[address.toLowerCase()] === undefined);
  if (missing.length > 0) throw new Error(`GetTokens returned no positive spotUsd for ${missing.join(", ")}`);
  return prices;
}
