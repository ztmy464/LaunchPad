import { createServer } from "node:http";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";
import {
  createPublicClient,
  formatEther,
  getAddress,
  http,
  isAddress,
  parseAbiItem,
} from "viem";

const __dirname = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(__dirname, "..");
const launchpadRoot = resolve(packageRoot, "..", "..");

const RPC_URL = process.env.MARKET_RPC_URL || "http://127.0.0.1:8545";
const HOST = process.env.MARKET_HOST || "127.0.0.1";
const PORT = Number(process.env.MARKET_PORT || 8787);
const CHAIN_ID = process.env.MARKET_CHAIN_ID || "31337";
const DATA_FILE =
  process.env.MARKET_DATA_FILE || join(packageRoot, "data", "market-data.json");
const DEPLOYMENTS_FILE =
  process.env.MARKET_DEPLOYMENTS_FILE ||
  join(launchpadRoot, "packages", "foundry", "deployments", `${CHAIN_ID}.json`);
const BROADCAST_FILE =
  process.env.MARKET_BROADCAST_FILE ||
  join(
    launchpadRoot,
    "packages",
    "foundry",
    "broadcast",
    "Deploy.s.sol",
    CHAIN_ID,
    "run-latest.json",
  );

const tokenLaunchedEvent = parseAbiItem(
  "event TokenLaunched(address indexed token, string name, string symbol, address indexed creator, uint256 timestamp)",
);
const tokensBoughtEvent = parseAbiItem(
  "event TokensBought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 fee)",
);
const tokensSoldEvent = parseAbiItem(
  "event TokensSold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 fee)",
);

const publicClient = createPublicClient({
  transport: http(RPC_URL),
});

const blockTimestampCache = new Map();
const clients = new Set();

let state = loadState();

function loadState() {
  try {
    return JSON.parse(readFileSync(DATA_FILE, "utf8"));
  } catch {
    return {
      tokens: [],
      trades: [],
      candles: [],
    };
  }
}

function saveState() {
  mkdirSync(dirname(DATA_FILE), { recursive: true });
  writeFileSync(DATA_FILE, JSON.stringify(state, null, 2));
}

function getTokenFactoryAddress() {
  if (process.env.MARKET_TOKEN_FACTORY_ADDRESS) {
    return getAddress(process.env.MARKET_TOKEN_FACTORY_ADDRESS);
  }

  const deployments = JSON.parse(readFileSync(DEPLOYMENTS_FILE, "utf8"));
  const factoryEntry = Object.entries(deployments).find(
    ([, name]) => name === "TokenFactory",
  );
  if (!factoryEntry) {
    throw new Error(`TokenFactory not found in ${DEPLOYMENTS_FILE}`);
  }
  return getAddress(factoryEntry[0]);
}

function getDeploymentBlock() {
  if (process.env.MARKET_START_BLOCK) {
    return BigInt(process.env.MARKET_START_BLOCK);
  }

  try {
    const broadcast = JSON.parse(readFileSync(BROADCAST_FILE, "utf8"));
    const tx = broadcast.transactions?.find(
      (item) => item.contractName === "TokenFactory",
    );
    const receipt = broadcast.receipts?.find(
      (item) => item.transactionHash?.toLowerCase() === tx?.hash?.toLowerCase(),
    );
    if (receipt?.blockNumber) {
      return BigInt(receipt.blockNumber);
    }
  } catch {
    // Fall back to genesis for local dev if broadcast artifacts are unavailable.
  }

  return 0n;
}

function normalizeTokenAddress(address) {
  return getAddress(address);
}

function addToken(address) {
  const tokenAddress = normalizeTokenAddress(address);
  if (
    !state.tokens.some(
      (item) => item.toLowerCase() === tokenAddress.toLowerCase(),
    )
  ) {
    state.tokens.push(tokenAddress);
    saveState();
  }
  return tokenAddress;
}

async function getBlockTimestamp(blockNumber) {
  const key = blockNumber.toString();
  if (blockTimestampCache.has(key)) return blockTimestampCache.get(key);

  const block = await publicClient.getBlock({ blockNumber });
  const timestamp = Number(block.timestamp);
  blockTimestampCache.set(key, timestamp);
  return timestamp;
}

function weiToDecimalString(value) {
  return formatEther(value);
}

function weiToNumber(value) {
  return Number(formatEther(value));
}

function calculatePrice(side, args) {
  if (side === "buy") {
    const quoteWei = args.ethIn > args.fee ? args.ethIn - args.fee : args.ethIn;
    const quote = weiToNumber(quoteWei);
    const base = weiToNumber(args.tokensOut);
    return base > 0 ? quote / base : 0;
  }

  const quoteWei = args.ethOut + args.fee;
  const quote = weiToNumber(quoteWei);
  const base = weiToNumber(args.tokensIn);
  return base > 0 ? quote / base : 0;
}

async function processTradeLog(log, side) {
  if (!log.transactionHash || log.logIndex === undefined || !log.blockNumber)
    return;

  const tokenAddress = addToken(log.address);
  const id = `${log.transactionHash}-${log.logIndex}`;
  if (state.trades.some((trade) => trade.id === id)) return;

  const timestampSeconds = await getBlockTimestamp(log.blockNumber);
  const timestamp = new Date(timestampSeconds * 1000).toISOString();
  const args = log.args;
  const price = calculatePrice(side, args);

  const trade =
    side === "buy"
      ? {
          id,
          tokenAddress,
          side,
          type: "Buy",
          trader: getAddress(args.buyer),
          senderAddress: getAddress(args.buyer),
          ethAmount: weiToDecimalString(args.ethIn),
          tokenAmount: weiToDecimalString(args.tokensOut),
          fee: weiToDecimalString(args.fee),
          price,
          txHash: log.transactionHash,
          blockNumber: Number(log.blockNumber),
          logIndex: Number(log.logIndex),
          timestamp,
          timestampSeconds,
        }
      : {
          id,
          tokenAddress,
          side,
          type: "Sell",
          trader: getAddress(args.seller),
          senderAddress: getAddress(args.seller),
          ethAmount: weiToDecimalString(args.ethOut),
          tokenAmount: weiToDecimalString(args.tokensIn),
          fee: weiToDecimalString(args.fee),
          price,
          txHash: log.transactionHash,
          blockNumber: Number(log.blockNumber),
          logIndex: Number(log.logIndex),
          timestamp,
          timestampSeconds,
        };

  state.trades.push(trade);
  upsertCandle(trade);
  saveState();

  broadcast({ type: "trade", tokenAddress, trade });
  const candle = getCandle(
    tokenAddress,
    Math.floor(timestampSeconds / 60) * 60,
  );
  if (candle) {
    broadcast({ type: "candle", tokenAddress, interval: "1m", candle });
  }

  console.log(
    `[market] ${trade.type} ${tokenAddress} price=${price} tx=${trade.txHash}`,
  );
}

function upsertCandle(trade) {
  const bucketTime = Math.floor(trade.timestampSeconds / 60) * 60;
  const tokenAddress = normalizeTokenAddress(trade.tokenAddress);
  const price = Number(trade.price);
  const volumeEth = Number(trade.ethAmount);
  const volumeToken = Number(trade.tokenAmount);
  const existing = getCandle(tokenAddress, bucketTime);

  if (!existing) {
    state.candles.push({
      tokenAddress,
      interval: "1m",
      time: bucketTime,
      open: price,
      high: price,
      low: price,
      close: price,
      volumeEth,
      volumeToken,
      tradeCount: 1,
    });
    return;
  }

  existing.high = Math.max(existing.high, price);
  existing.low = Math.min(existing.low, price);
  existing.close = price;
  existing.volumeEth += volumeEth;
  existing.volumeToken += volumeToken;
  existing.tradeCount += 1;
}

function getCandle(tokenAddress, bucketTime) {
  return state.candles.find(
    (candle) =>
      candle.tokenAddress.toLowerCase() === tokenAddress.toLowerCase() &&
      candle.interval === "1m" &&
      candle.time === bucketTime,
  );
}

function getTrades(tokenAddress, limit) {
  return state.trades
    .filter(
      (trade) =>
        trade.tokenAddress.toLowerCase() === tokenAddress.toLowerCase(),
    )
    .sort(
      (a, b) =>
        b.timestampSeconds - a.timestampSeconds || b.logIndex - a.logIndex,
    )
    .slice(0, limit);
}

function getCandles(tokenAddress, limit) {
  return state.candles
    .filter(
      (candle) =>
        candle.tokenAddress.toLowerCase() === tokenAddress.toLowerCase() &&
        candle.interval === "1m",
    )
    .sort((a, b) => a.time - b.time)
    .slice(-limit)
    .map(
      ({
        tokenAddress: _tokenAddress,
        interval: _interval,
        volumeEth: _volumeEth,
        volumeToken: _volumeToken,
        tradeCount: _tradeCount,
        ...candle
      }) => candle,
    );
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  });
  res.end(body);
}

function createHttpServer() {
  return createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const parts = url.pathname.split("/").filter(Boolean);

    if (url.pathname === "/health") {
      sendJson(res, 200, {
        ok: true,
        rpcUrl: RPC_URL,
        tokens: state.tokens.length,
        trades: state.trades.length,
        candles: state.candles.length,
      });
      return;
    }

    if (
      parts[0] === "api" &&
      parts[1] === "tokens" &&
      parts[2] &&
      parts[3] === "trades"
    ) {
      if (!isAddress(parts[2])) {
        sendJson(res, 400, { error: "Invalid token address" });
        return;
      }
      const limit = Math.min(Number(url.searchParams.get("limit") || 50), 200);
      sendJson(res, 200, { data: getTrades(getAddress(parts[2]), limit) });
      return;
    }

    if (
      parts[0] === "api" &&
      parts[1] === "tokens" &&
      parts[2] &&
      parts[3] === "candles"
    ) {
      if (!isAddress(parts[2])) {
        sendJson(res, 400, { error: "Invalid token address" });
        return;
      }
      const interval = url.searchParams.get("interval") || "1m";
      if (interval !== "1m") {
        sendJson(res, 400, {
          error: "Only 1m interval is supported in the demo server",
        });
        return;
      }
      const limit = Math.min(
        Number(url.searchParams.get("limit") || 300),
        1000,
      );
      sendJson(res, 200, { data: getCandles(getAddress(parts[2]), limit) });
      return;
    }

    sendJson(res, 404, { error: "Not found" });
  });
}

function broadcast(message) {
  const body = JSON.stringify(message);
  for (const client of clients) {
    if (client.readyState !== 1) continue;
    if (
      client.tokenAddress &&
      client.tokenAddress.toLowerCase() !== message.tokenAddress?.toLowerCase()
    )
      continue;
    client.send(body);
  }
}

function attachWebSocket(server) {
  const wss = new WebSocketServer({ server, path: "/ws" });

  wss.on("connection", (socket, req) => {
    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const token = url.searchParams.get("token");
    socket.tokenAddress = token && isAddress(token) ? getAddress(token) : null;
    clients.add(socket);
    socket.send(
      JSON.stringify({ type: "connected", tokenAddress: socket.tokenAddress }),
    );

    socket.on("close", () => {
      clients.delete(socket);
    });
  });
}

async function syncHistoricalEvents(factoryAddress, fromBlock) {
  const latestBlock = await publicClient.getBlockNumber();
  console.log(`[market] syncing from block ${fromBlock} to ${latestBlock}`);

  const launchedLogs = await publicClient.getLogs({
    address: factoryAddress,
    event: tokenLaunchedEvent,
    fromBlock,
    toBlock: latestBlock,
  });

  for (const log of launchedLogs) {
    if (log.args.token) addToken(log.args.token);
  }

  for (const tokenAddress of state.tokens) {
    const buyLogs = await publicClient.getLogs({
      address: tokenAddress,
      event: tokensBoughtEvent,
      fromBlock,
      toBlock: latestBlock,
    });
    for (const log of buyLogs) await processTradeLog(log, "buy");

    const sellLogs = await publicClient.getLogs({
      address: tokenAddress,
      event: tokensSoldEvent,
      fromBlock,
      toBlock: latestBlock,
    });
    for (const log of sellLogs) await processTradeLog(log, "sell");
  }

  console.log(
    `[market] tokens=${state.tokens.length} trades=${state.trades.length} candles=${state.candles.length}`,
  );
}

function watchLiveEvents(factoryAddress) {
  publicClient.watchEvent({
    address: factoryAddress,
    event: tokenLaunchedEvent,
    pollingInterval: 1000,
    onLogs: (logs) => {
      for (const log of logs) {
        if (log.args.token) {
          const tokenAddress = addToken(log.args.token);
          console.log(`[market] token launched ${tokenAddress}`);
        }
      }
    },
    onError: (error) =>
      console.error("[market] TokenLaunched watcher error", error),
  });

  publicClient.watchEvent({
    event: tokensBoughtEvent,
    pollingInterval: 1000,
    onLogs: (logs) => logs.forEach((log) => void processTradeLog(log, "buy")),
    onError: (error) =>
      console.error("[market] TokensBought watcher error", error),
  });

  publicClient.watchEvent({
    event: tokensSoldEvent,
    pollingInterval: 1000,
    onLogs: (logs) => logs.forEach((log) => void processTradeLog(log, "sell")),
    onError: (error) =>
      console.error("[market] TokensSold watcher error", error),
  });
}

async function main() {
  const factoryAddress = getTokenFactoryAddress();
  const fromBlock = getDeploymentBlock();

  await syncHistoricalEvents(factoryAddress, fromBlock);

  const server = createHttpServer();
  attachWebSocket(server);
  server.listen(PORT, HOST, () => {
    console.log(`[market] listening on http://${HOST}:${PORT}`);
    console.log(
      `[market] websocket ws://${HOST}:${PORT}/ws?token=<tokenAddress>`,
    );
    console.log(`[market] factory ${factoryAddress}`);
  });

  watchLiveEvents(factoryAddress);
}

main().catch((error) => {
  console.error("[market] fatal", error);
  process.exit(1);
});
