# Example Token Launcher

> **Note:** This is a test application built to demonstrate and test **"Ethereum Wingman"** - an AI skill I'm developing for Cursor/Claude that helps developers build Ethereum dApps.

## What is Ethereum Wingman?

Ethereum Wingman is an AI coding assistant skill that guides developers through building Scaffold-ETH 2 projects. It provides:

- Smart contract development guidance (Solidity best practices, security patterns)
- Frontend integration with wagmi/viem hooks
- Testing workflows using Foundry fork mode against real protocol state
- Knowledge of common pitfalls and historical DeFi exploits

The skill files are located in `.agents/skills/ethereum-wingman/`.

## The Test App: Token Launchpad

This repository contains a token launchpad dApp built with Scaffold-ETH 2, featuring:

- **Bonding Curve** - Automated price discovery where token price increases with supply
- **Sniper Protection** - 60-second cooldown giving early buyers proportionally fewer tokens
- **Creator Fees** - 1% buy fee / 2% sell fee going to the token creator
- **Graduation to Uniswap V4** - When reserve reaches 0.1 ETH, tokens graduate to a real DEX pool

## Project Structure

```
├── context.md                    # Detailed project documentation
├── launchpad/                    # Scaffold-ETH 2 monorepo
│   ├── packages/foundry/         # Smart contracts (Solidity + Foundry)
│   │   ├── contracts/
│   │   │   ├── TokenFactory.sol      # Deploys token proxies
│   │   │   ├── LaunchToken.sol       # ERC-20 with bonding curve
│   │   │   ├── SimplePool.sol        # Uniswap V4 pool creation
│   │   │   └── TradeFeeHook.sol      # V4 trading fee hook
│   │   └── script/
│   │       └── DeployLaunchpadFork.s.sol
│   └── packages/nextjs/          # Frontend (Next.js + wagmi)
│       └── app/
│           ├── page.tsx              # Home - token list
│           ├── create/page.tsx       # Create new token
│           └── token/[address]/page.tsx  # Token trading UI
└── .agents/skills/ethereum-wingman/  # The AI skill being tested
```

## Running Locally

```bash
# Terminal 1: Start Anvil fork
cd launchpad/packages/foundry
anvil --fork-url <YOUR_MAINNET_RPC>

# Terminal 2: Deploy contracts
forge script script/DeployLaunchpadFork.s.sol --rpc-url http://localhost:8545 --broadcast

# Terminal 3: Start frontend
cd launchpad/packages/nextjs
yarn dev
```

Then open http://localhost:3000

## About

Built by [Austin Griffith](https://github.com/austintgriffith) as a test case for the Ethereum Wingman AI skill.
