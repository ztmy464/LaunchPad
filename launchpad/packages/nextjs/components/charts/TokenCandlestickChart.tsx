"use client";

import { useEffect, useRef } from "react";
import { CrosshairMode, Time, createChart } from "lightweight-charts";
import type { IChartApi } from "lightweight-charts";
import type { CandleDataPoint } from "~~/types/market";

type TokenCandlestickChartProps = {
  data: CandleDataPoint[];
  height?: number;
  watermark?: string;
};

export const TokenCandlestickChart = ({ data, height = 420, watermark = "Launchpad" }: TokenCandlestickChartProps) => {
  const chartContainerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);

  useEffect(() => {
    if (!chartContainerRef.current || data.length < 2) return;

    const container = chartContainerRef.current;
    const chart = createChart(container, {
      width: container.clientWidth,
      height,
      layout: {
        background: { color: "transparent" },
        textColor: "#94a3b8",
      },
      grid: {
        vertLines: { color: "rgba(148, 163, 184, 0.14)" },
        horzLines: { color: "rgba(148, 163, 184, 0.14)" },
      },
      rightPriceScale: {
        borderColor: "rgba(148, 163, 184, 0.28)",
        visible: true,
        borderVisible: true,
        alignLabels: true,
        entireTextOnly: true,
        scaleMargins: {
          top: 0.12,
          bottom: 0.12,
        },
      },
      timeScale: {
        borderColor: "rgba(148, 163, 184, 0.28)",
        timeVisible: true,
        secondsVisible: false,
      },
      crosshair: {
        mode: CrosshairMode.Normal,
      },
      watermark: {
        color: "rgba(148, 163, 184, 0.14)",
        visible: true,
        text: watermark,
        fontSize: 24,
        horzAlign: "center",
        vertAlign: "center",
      },
    });

    const candleSeries = chart.addCandlestickSeries({
      upColor: "#34eeb6",
      downColor: "#ff8863",
      borderVisible: false,
      wickUpColor: "#34eeb6",
      wickDownColor: "#ff8863",
    });

    const chartData = enhanceSmallCandles(normalizeCandles(data));

    candleSeries.setData(
      chartData.map(item => ({
        time: item.time as Time,
        open: item.open,
        high: item.high,
        low: item.low,
        close: item.close,
      })),
    );

    candleSeries.applyOptions({
      priceFormat: {
        type: "custom",
        formatter: formatPriceLabel,
        minMove: 1e-9,
      },
    });

    chart.timeScale().fitContent();
    chartRef.current = chart;

    const resizeObserver = new ResizeObserver(entries => {
      const [entry] = entries;
      if (!entry) return;
      chart.applyOptions({ width: Math.floor(entry.contentRect.width) });
    });

    resizeObserver.observe(container);

    return () => {
      resizeObserver.disconnect();
      chart.remove();
      chartRef.current = null;
    };
  }, [data, height, watermark]);

  return <div ref={chartContainerRef} className="h-full w-full" />;
};

const normalizeCandles = (data: CandleDataPoint[]) => {
  const sortedData = [...data].sort((a, b) => a.time - b.time);
  return sortedData.reduce<CandleDataPoint[]>((acc, item) => {
    const previous = acc[acc.length - 1];
    if (!previous || previous.time !== item.time) {
      acc.push(item);
    }
    return acc;
  }, []);
};

const enhanceSmallCandles = (data: CandleDataPoint[]) => {
  const minCandleSize = 1e-9;
  return data.map(item => {
    const bodySize = Math.abs(item.open - item.close);
    if (bodySize >= minCandleSize) return item;

    const midPoint = (item.open + item.close) / 2;
    const adjustment = minCandleSize / 2;

    return {
      ...item,
      open: midPoint - adjustment,
      close: midPoint + adjustment,
      high: Math.max(item.high, midPoint + adjustment),
      low: Math.min(item.low, midPoint - adjustment),
    };
  });
};

const formatPriceLabel = (price: number) => {
  const abs = Math.abs(price);
  if (abs >= 1) return price.toFixed(4);
  if (abs >= 0.1) return price.toFixed(5);
  if (abs >= 0.01) return price.toFixed(6);
  if (abs >= 0.001) return price.toFixed(7);
  return price.toFixed(8);
};
