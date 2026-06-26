import type { CandleDataPoint, TradeDataPoint } from "~~/types/market";

const DEFAULT_MARKET_API_URL = "http://127.0.0.1:8787";

export const getMarketApiUrl = () =>
  (process.env.NEXT_PUBLIC_MARKET_API_URL || DEFAULT_MARKET_API_URL).replace(/\/$/, "");

export const getMarketWsUrl = (tokenAddress: string) => {
  const apiUrl = getMarketApiUrl();
  const wsUrl = apiUrl.replace(/^https:/, "wss:").replace(/^http:/, "ws:");
  return `${wsUrl}/ws?token=${tokenAddress}`;
};

export const fetchTokenCandles = async (tokenAddress: string): Promise<CandleDataPoint[]> => {
  const response = await fetch(`${getMarketApiUrl()}/api/tokens/${tokenAddress}/candles?interval=1m&limit=300`, {
    cache: "no-store",
  });
  if (!response.ok) throw new Error("Failed to fetch candles");
  const payload = (await response.json()) as { data?: CandleDataPoint[] };
  return payload.data || [];
};

export const fetchTokenTrades = async (tokenAddress: string): Promise<TradeDataPoint[]> => {
  const response = await fetch(`${getMarketApiUrl()}/api/tokens/${tokenAddress}/trades?limit=50`, {
    cache: "no-store",
  });
  if (!response.ok) throw new Error("Failed to fetch trades");
  const payload = (await response.json()) as { data?: TradeDataPoint[] };
  return payload.data || [];
};
