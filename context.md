# Token Launchpad - Project Summary

## Overview

A **Scaffold-ETH 2** dApp that allows users to launch ERC-20 tokens with an automated **bonding curve** for price discovery. When enough liquidity accumulates, tokens "graduate" to a **Uniswap V4 pool** for real DEX trading.

## How It Works

1. **Create Token** - User enters name & symbol, deploys via `TokenFactory`
2. **Bonding Curve Trading** - Buy/sell tokens against an automated price curve
   - Price increases as supply grows (quadratic formula)
   - **1% buy fee** and **2% sell fee** go to creator's treasury
   - **99% of buy ETH** goes to `reserveBalance` (liquidity pool)
3. **Sniper Protection** - First 60 seconds after launch, early buyers receive proportionally fewer tokens (penalty = tokens × elapsed/60)
4. **Graduation** - When `reserveBalance` reaches **0.1 ETH**, the token graduates:
   - Bonding curve is disabled
   - Reserve ETH + minted tokens seed a Uniswap V4 pool
5. **Post-Graduation** - Trading continues on Uniswap V4 with fee hooks

---

## ⚠️ IMPORTANT: Testing All Changes

**ALWAYS TEST CHANGES USING THE BROWSER.** After any code modification, you MUST:

1. **Create a fresh token** via `/create` page
2. **Test ALL phases** by buying and selling through the UI:

### Phase 1: Sniper Protection (first 60 seconds)

- [ ] Buy immediately after token creation
- [ ] Verify estimate shows reduced tokens (may show 0 early on - this is expected)
- [ ] Confirm actual tokens received are less than post-protection
- [ ] Try selling during this period

### Phase 2: Normal Bonding Curve Trading

- [ ] Wait for sniper protection to end (60s)
- [ ] Buy with 0.001, 0.01, 0.1 ETH - verify estimates match actual
- [ ] Sell tokens - verify 2% fee is applied
- [ ] Check that "Bonding Curve Reserve" increases with buys
- [ ] Check that "Creator Earnings" (treasury) accumulates fees
- [ ] Verify graduation progress bar updates correctly

### Phase 3: Graduation

- [ ] Continue buying until reserve reaches 0.1 ETH
- [ ] Verify status changes from "Bonding Curve" to "Graduated"
- [ ] Confirm bonding curve buy/sell is disabled

### Phase 4: Uniswap V4 Pool

- [ ] Click "Create Pool" button
- [ ] Buy tokens from V4 pool
- [ ] Sell tokens to V4 pool
- [ ] Verify pool trading works correctly

### Creator Actions

- [ ] Test "Withdraw" button for creator earnings
- [ ] Verify only creator can withdraw

---

## Key Files

### Smart Contracts (`launchpad/packages/foundry/contracts/`)

| File                             | Purpose                                                              |
| -------------------------------- | -------------------------------------------------------------------- |
| `TokenFactory.sol`               | Deploys LaunchToken proxies, manages graduation funds                |
| `LaunchToken.sol`                | ERC-20 with bonding curve, fees, sniper protection, graduation logic |
| `SimplePool.sol`                 | Creates Uniswap V4 pools for graduated tokens                        |
| `TradeFeeHook.sol`               | Uniswap V4 hook for post-graduation trading fees                     |
| `libraries/BondingCurveMath.sol` | Constants and math for bonding curve calculations                    |

### Frontend (`launchpad/packages/nextjs/`)

| File                             | Purpose                                                    |
| -------------------------------- | ---------------------------------------------------------- |
| `app/page.tsx`                   | Home page - lists all tokens, shows platform stats         |
| `app/create/page.tsx`            | Token creation form                                        |
| `app/token/[address]/page.tsx`   | Token detail page - trading UI, stats, graduation progress |
| `contracts/externalContracts.ts` | ABI definitions for LaunchToken, TokenFactory, SimplePool  |

## Key Contract Functions

**LaunchToken.sol:**

- `buy()` - Buy tokens with ETH (applies fee + sniper penalty if active)
- `sell(amount)` - Sell tokens for ETH (applies 2% fee)
- `estimateBuy(ethAmount)` - View function for buy preview
- `estimateSell(tokenAmount)` - View function for sell preview
- `withdrawTreasury()` - Creator withdraws accumulated fees
- `graduationProgress()` - Returns 0-100 based on reserveBalance/0.1 ETH
- `getTokensForLiquidity(ethAmount)` - Calculates tokens needed for liquidity at current bonding curve price
- `getContractTokenBalance()` - Returns tokens held by contract (for liquidity)

**TokenFactory.sol:**

- `createToken(name, symbol)` - Deploy new LaunchToken proxy
- `createGraduatedPool(token)` - Create SimplePool with graduation funds and price continuity
- `graduationFunds(token)` - View graduation ETH held for a token
- `setSimplePool(address)` - Admin: set SimplePool address

**Key State Variables:**

- `reserveBalance` - ETH for V4 liquidity (graduation metric)
- `treasury` - Creator earnings from fees
- `totalSupply` - Tokens in circulation
- `graduated` - Boolean flag
- `launchTime` - Used for sniper protection calculation

## Recent Changes

1. **Graduation threshold** changed from 0.005 ETH to **0.1 ETH**
2. **Graduation metric** changed from `treasury` to `reserveBalance`
3. Added **`withdrawTreasury()`** function for creator to claim fees
4. Frontend updated to show both "Bonding Curve Reserve" and "Creator Earnings" separately
5. Fixed estimate display to show **4 decimal places** (e.g., "6.0000 NEWT" instead of "0")
6. Updated all UI text to reference "reserve" instead of "treasury" for graduation
7. **Fixed price continuity bug** - Pool creation now uses graduation funds and calculates correct token amounts based on final bonding curve price (ensures first pool purchase gives similar tokens to last curve purchase)
8. Added **`createGraduatedPool(token)`** to TokenFactory - atomically creates pools with price continuity
9. Added **`getTokensForLiquidity(ethAmount)`** to LaunchToken - calculates tokens needed for liquidity at current price

## Local Setup

```bash
cd launchpad/packages/foundry
anvil --fork-url <MAINNET_RPC>  # Fork mode for Uniswap V4

# In another terminal
forge script script/DeployLaunchpadFork.s.sol --rpc-url http://localhost:8545 --broadcast

cd ../nextjs
yarn dev
```

Then open `http://localhost:3000` in browser.

## Known Behaviors

- During sniper protection, estimates are intentionally inaccurate (anti-bot measure)
- The "Create Pool" function requires manual invocation after graduation, but now uses graduation funds automatically with price continuity
- Creator can withdraw treasury (fees) at any time via the Withdraw button
- Pool creation ensures the first pool purchase gives approximately the same tokens as the last bonding curve purchase (price continuity)

## Architecture Notes

- Uses **ERC-1167 minimal proxy** pattern for gas-efficient token deployment
- **OpenZeppelin Initializable** for upgradeable proxy pattern
- Bonding curve uses quadratic formula: `price = BASE_PRICE + PRICE_INCREMENT × supply`
- All ETH amounts use 18 decimals (wei)
