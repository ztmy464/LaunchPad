# LaunchPad - Project Context

`LaunchPad` is a token launchpad demo built on Scaffold-ETH 2. It launches ERC-20 tokens through a bonding curve, then graduates successful tokens into a Uniswap V2 pool for normal trading.

## Core Areas

- LaunchPad contracts
- Next.js frontend
- Real-time market data server
- Foundry deploy scripts
- Launch flow and graduation logic

## Frontend Stack

- Next.js
- Tailwind CSS
- Scaffold-ETH 2 hooks
- Web3 wallet integration

## Market Data

- Trades are indexed by the local market server
- Candles are derived from on-chain buy and sell events
- The frontend subscribes to live updates over WebSocket

## Product Goal

- Token list homepage
- Token detail trade panel
- Live charting
- Recent trades
- Simple demo slippage controls
