export type CandleDataPoint = {
  time: number;
  open: number;
  high: number;
  low: number;
  close: number;
};

export type TradeDataPoint = {
  id: string;
  tokenAddress: string;
  side: "buy" | "sell";
  type: "Buy" | "Sell";
  trader: string;
  senderAddress: string;
  ethAmount: string;
  tokenAmount: string;
  fee: string;
  price: number;
  txHash: string;
  blockNumber: number;
  logIndex: number;
  timestamp: string;
  timestampSeconds: number;
};
