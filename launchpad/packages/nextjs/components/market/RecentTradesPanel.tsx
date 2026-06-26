"use client";

import Link from "next/link";
import { ArrowTopRightOnSquareIcon } from "@heroicons/react/24/outline";
import type { TradeDataPoint } from "~~/types/market";

type RecentTradesPanelProps = {
  trades: TradeDataPoint[];
  tokenSymbol: string;
  isLive?: boolean;
};

export const RecentTradesPanel = ({ trades, tokenSymbol, isLive = false }: RecentTradesPanelProps) => {
  return (
    <div className="card bg-base-100 shadow-xl">
      <div className="card-body">
        <div className="flex items-center justify-between gap-3">
          <h2 className="card-title">Recent Trades</h2>
          <div className={`badge ${isLive ? "badge-success" : "badge-outline"}`}>{isLive ? "Live" : "Offline"}</div>
        </div>

        <div className="mt-2 overflow-hidden rounded-lg border border-base-300">
          <table className="table hidden md:table">
            <thead>
              <tr className="bg-base-200">
                <th>Maker</th>
                <th>Type</th>
                <th>ETH</th>
                <th>{tokenSymbol}</th>
                <th>Price</th>
                <th>Time</th>
                <th>Tx</th>
              </tr>
            </thead>
            <tbody>
              {trades.map(trade => (
                <tr key={trade.id} className="hover:bg-base-200/70">
                  <td className="font-mono text-xs">{shortAddress(trade.trader)}</td>
                  <td>
                    <span className={`badge ${trade.side === "buy" ? "badge-success" : "badge-error"} badge-outline`}>
                      {trade.type}
                    </span>
                  </td>
                  <td className="font-mono text-xs">{formatAmount(trade.ethAmount)}</td>
                  <td className="font-mono text-xs">{formatAmount(trade.tokenAmount)}</td>
                  <td className="font-mono text-xs">{formatPrice(trade.price)}</td>
                  <td className="text-xs text-base-content/60">{formatTime(trade.timestamp)}</td>
                  <td>
                    <Link
                      href={`/blockexplorer/transaction/${trade.txHash}`}
                      className="inline-flex items-center gap-1 text-xs text-primary hover:underline"
                    >
                      {trade.txHash.slice(0, 8)}
                      <ArrowTopRightOnSquareIcon className="h-3 w-3" />
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>

          <div className="space-y-2 p-3 md:hidden">
            {trades.map(trade => (
              <div key={trade.id} className="rounded-lg border border-base-300 bg-base-200/70 p-3">
                <div className="flex items-center justify-between gap-2">
                  <span className={`badge ${trade.side === "buy" ? "badge-success" : "badge-error"} badge-outline`}>
                    {trade.type}
                  </span>
                  <Link
                    href={`/blockexplorer/transaction/${trade.txHash}`}
                    className="inline-flex items-center gap-1 text-xs text-primary"
                  >
                    View Tx
                    <ArrowTopRightOnSquareIcon className="h-3 w-3" />
                  </Link>
                </div>
                <div className="mt-2 grid grid-cols-2 gap-2 text-xs">
                  <span className="text-base-content/60">Maker</span>
                  <span className="text-right font-mono">{shortAddress(trade.trader)}</span>
                  <span className="text-base-content/60">ETH</span>
                  <span className="text-right font-mono">{formatAmount(trade.ethAmount)}</span>
                  <span className="text-base-content/60">{tokenSymbol}</span>
                  <span className="text-right font-mono">{formatAmount(trade.tokenAmount)}</span>
                  <span className="text-base-content/60">Price</span>
                  <span className="text-right font-mono">{formatPrice(trade.price)}</span>
                  <span className="text-base-content/60">Time</span>
                  <span className="text-right">{formatTime(trade.timestamp)}</span>
                </div>
              </div>
            ))}
          </div>

          {trades.length === 0 && (
            <div className="flex min-h-32 items-center justify-center text-sm text-base-content/60">No trades yet</div>
          )}
        </div>
      </div>
    </div>
  );
};

const shortAddress = (address: string) => `${address.slice(0, 6)}...${address.slice(-4)}`;

const formatAmount = (value: string) => {
  const amount = Number(value);
  if (!Number.isFinite(amount)) return value;
  if (amount === 0) return "0";
  if (amount < 0.000001) return amount.toExponential(2);
  return amount.toLocaleString("en-US", { maximumFractionDigits: 6 });
};

const formatPrice = (value: number) => {
  if (!Number.isFinite(value)) return "-";
  if (value === 0) return "0";
  if (value < 0.00000001) return value.toExponential(2);
  return value.toFixed(value >= 1 ? 6 : 10).replace(/\.?0+$/, "");
};

const formatTime = (timestamp: string) => {
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return "-";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
};
