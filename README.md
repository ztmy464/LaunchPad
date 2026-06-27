# LaunchPad

`LaunchPad` is a token launchpad demo built on Scaffold-ETH 2. It is the frontend base I am using to prototype a Pump.fun-style launchpad on EVM chains.

The project now includes:

- Token list homepage with graduation progress
- Token detail page with trade panel
- Real-time market data service for candles and recent trades
- Candlestick chart rendering with `lightweight-charts`
- Recent trades panel inspired by `Pump-UI-bondle`
- Local anvil workflow for development and testing

## What This Demo Covers

- Bonding curve token launches
- Sniper protection / cooldown display
- Buy and sell actions from the frontend
- Real-time trade feed and 1m candle updates
- Trade history display under the trading panel
- Simple slippage UI for demo purposes

## Project Structure

```text
launchpad/
  packages/
    foundry/
      contracts/        Solidity contracts and launch logic
      script/           Foundry deployment scripts
    nextjs/
      app/              Next.js routes and pages
      components/       UI components
      hooks/            Frontend data hooks
      utils/            Shared market/client helpers
    market-server/
      src/server.js     Local market data server
```

## How It Works

- `packages/foundry` deploys the launchpad contracts.
- `packages/market-server` listens to on-chain events, computes trade prices, stores `trades` and `candles`, and pushes updates over WebSocket.
- `packages/nextjs` reads initial market data over REST and subscribes to WebSocket updates for live chart/trade refreshes.

The market server is a local demo backend. It is not part of the on-chain contracts.

## Local Development

From `launchpad/`:

```bash
yarn install
yarn market:server
yarn workspace @se-2/nextjs dev -p 3002
```

If you also want to run the chain and deploy locally:

```bash
cd packages/foundry
anvil --fork-url <YOUR_RPC_URL> --chain-id 31337 --block-time 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --ffi
```

## Main Features

- Homepage token list with progress display
- Token detail trade screen
- Live 1m chart updates from market events
- Recent trades list below the trade panel
- Demo slippage settings UI
- Local market data persistence for fast refreshes

## Notes

- The current slippage control is a frontend demo control.
- The market server keeps `trades` and `candles` in local storage for the demo workflow.
- The project is still a work in progress and the contracts, frontend, and local data service are evolving together.
