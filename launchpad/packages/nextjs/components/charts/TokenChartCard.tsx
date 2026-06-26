"use client";

import { TokenCandlestickChart } from "~~/components/charts/TokenCandlestickChart";
import type { CandleDataPoint } from "~~/types/market";

type TokenChartCardProps = {
  candles: CandleDataPoint[];
  isLoading?: boolean;
  title?: string;
  watermark?: string;
};

export const TokenChartCard = ({
  candles,
  isLoading = false,
  title = "Price Chart",
  watermark,
}: TokenChartCardProps) => {
  return (
    <div className="card bg-base-100 shadow-xl">
      <div className="card-body">
        <div className="flex items-center justify-between gap-3">
          <h2 className="card-title">{title}</h2>
          <div className="badge badge-outline">1m</div>
        </div>

        <div className="mt-2 h-[420px] overflow-hidden rounded-lg border border-base-300 bg-base-200/70">
          {isLoading ? (
            <div className="flex h-full items-center justify-center">
              <span className="loading loading-spinner loading-lg" />
            </div>
          ) : candles.length < 2 ? (
            <div className="flex h-full items-center justify-center text-base-content/60">
              Not enough data to display chart
            </div>
          ) : (
            <TokenCandlestickChart data={candles} watermark={watermark} />
          )}
        </div>
      </div>
    </div>
  );
};
