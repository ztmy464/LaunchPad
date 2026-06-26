import { formatEther } from "viem";
import type { CandleDataPoint } from "~~/types/market";

const ONE_MINUTE = 60;

const hashAddress = (address: string) => {
  let hash = 2166136261;
  for (let i = 0; i < address.length; i++) {
    hash ^= address.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
};

const seededRandom = (seed: number) => {
  let state = seed || 1;
  return () => {
    state = Math.imul(1664525, state) + 1013904223;
    return (state >>> 0) / 4294967296;
  };
};

export const buildDemoCandles = ({
  tokenAddress,
  currentPrice,
  count = 72,
}: {
  tokenAddress: string;
  currentPrice?: bigint;
  count?: number;
}): CandleDataPoint[] => {
  const seed = hashAddress(tokenAddress);
  const random = seededRandom(seed);
  const parsedPrice = currentPrice ? Number(formatEther(currentPrice)) : 0;
  const anchorPrice = parsedPrice > 0 ? parsedPrice : 0.000001;
  const endTime = 1_735_689_600 + (seed % 10_000) * ONE_MINUTE;

  let close = anchorPrice * (0.82 + random() * 0.24);

  return Array.from({ length: count }, (_, index) => {
    const open = close;
    const drift = (random() - 0.46) * 0.055;
    close = Math.max(anchorPrice * 0.15, open * (1 + drift));
    const wick = Math.max(open, close) * (0.01 + random() * 0.035);
    const high = Math.max(open, close) + wick;
    const low = Math.max(0, Math.min(open, close) - wick * (0.55 + random() * 0.45));

    return {
      time: endTime - (count - index - 1) * ONE_MINUTE,
      open,
      high,
      low,
      close,
    };
  });
};
