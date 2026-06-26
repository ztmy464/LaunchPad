"use client";

import { useCallback, useEffect, useState } from "react";
import type { CandleDataPoint, TradeDataPoint } from "~~/types/market";
import { fetchTokenCandles, fetchTokenTrades, getMarketWsUrl } from "~~/utils/marketClient";

type MarketWsMessage =
  | { type: "connected"; tokenAddress: string | null }
  | { type: "trade"; tokenAddress: string; trade: TradeDataPoint }
  | { type: "candle"; tokenAddress: string; interval: "1m"; candle: CandleDataPoint };

export const useTokenMarketData = (tokenAddress: `0x${string}`) => {
  const [candles, setCandles] = useState<CandleDataPoint[]>([]);
  const [trades, setTrades] = useState<TradeDataPoint[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [isLive, setIsLive] = useState(false);

  const refetchMarketData = useCallback(async () => {
    if (!tokenAddress) return;

    setIsLoading(true);
    try {
      const [nextCandles, nextTrades] = await Promise.all([
        fetchTokenCandles(tokenAddress),
        fetchTokenTrades(tokenAddress),
      ]);
      setCandles(nextCandles);
      setTrades(nextTrades);
    } catch (error) {
      console.warn("Market data unavailable", error);
    } finally {
      setIsLoading(false);
    }
  }, [tokenAddress]);

  useEffect(() => {
    refetchMarketData();
  }, [refetchMarketData]);

  useEffect(() => {
    if (!tokenAddress) return;

    const socket = new WebSocket(getMarketWsUrl(tokenAddress));

    socket.onopen = () => setIsLive(true);
    socket.onclose = () => setIsLive(false);
    socket.onerror = () => setIsLive(false);
    socket.onmessage = event => {
      const message = JSON.parse(event.data) as MarketWsMessage;

      if (message.type === "trade") {
        setTrades(previous => upsertTrade(previous, message.trade));
      }

      if (message.type === "candle") {
        setCandles(previous => upsertCandle(previous, message.candle));
      }
    };

    return () => {
      socket.close();
    };
  }, [tokenAddress]);

  return {
    candles,
    trades,
    isLoading,
    isLive,
    refetchMarketData,
  };
};

const upsertTrade = (trades: TradeDataPoint[], trade: TradeDataPoint) => {
  const nextTrades = [trade, ...trades.filter(item => item.id !== trade.id)];
  return nextTrades.sort((a, b) => b.timestampSeconds - a.timestampSeconds || b.logIndex - a.logIndex).slice(0, 50);
};

const upsertCandle = (candles: CandleDataPoint[], candle: CandleDataPoint) => {
  const index = candles.findIndex(item => item.time === candle.time);
  if (index === -1) {
    return [...candles, candle].sort((a, b) => a.time - b.time).slice(-300);
  }

  const nextCandles = [...candles];
  nextCandles[index] = candle;
  return nextCandles.sort((a, b) => a.time - b.time).slice(-300);
};
