# Token Launchpad - Project Context

## Overview

A **Scaffold-ETH 2** dApp for launching ERC-20 tokens with an automated **bonding curve** for price discovery. When enough liquidity accumulates, tokens "graduate" to a **Uniswap V2 pool** for real DEX trading.

**Tech Stack:**
- Foundry (smart contracts)
- Next.js 15 (frontend)
- Scaffold-ETH 2 hooks
- Base fork for development (real Uniswap V2 Router)

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         TOKEN LIFECYCLE                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. CREATE          2. BONDING CURVE         3. GRADUATION              │
│  ────────          ───────────────          ────────────               │
│  TokenFactory      LaunchToken              TokenFactory                │
│  .createToken()    .buy() / .sell()         .createGraduatedPool()     │
│       │                  │                         │                    │
│       ▼                  ▼                         ▼                    │
│  ERC-1167 proxy    Price increases         V2 Pair created             │
│  LaunchToken       with supply             ETH + tokens seeded         │
│                    1% buy fee              Token registered with        │
│                    2% sell fee             CreatorFeeRouter            │
│                         │                         │                    │
│                         ▼                         ▼                    │
│                    When reserveBalance     4. POST-GRADUATION          │
│                    >= 0.02 ETH             ──────────────────          │
│                    → sends ETH to          Trade on V2 via             │
│                      factory               CreatorFeeRouter            │
│                                            (2% fee to creator)         │
│                                            OR direct on Uniswap        │
│                                            (no fee)                    │
└─────────────────────────────────────────────────────────────────────────┘
```

### Token Phases

| Phase | Duration | Trading | Fees |
|-------|----------|---------|------|
| **Sniper Protection** | First 60 seconds | Bonding curve (penalized) | 1% buy, 2% sell |
| **Normal Bonding Curve** | Until graduation | Bonding curve | 1% buy, 2% sell |
| **Graduated** | Forever | Uniswap V2 pool | 2% via CreatorFeeRouter (optional) |

---

## Project Structure

```
sc3/
├── context.md                    # This file
├── launchpad/
│   └── packages/
│       ├── foundry/
│       │   ├── contracts/
│       │   │   ├── TokenFactory.sol        # Factory + pool creation
│       │   │   ├── LaunchToken.sol         # ERC-20 + bonding curve
│       │   │   ├── CreatorFeeRouter.sol    # V2 swap wrapper with fees
│       │   │   └── libraries/
│       │   │       └── BondingCurveMath.sol # Price formulas + constants
│       │   └── script/
│       │       └── DeployLaunchpadFork.s.sol # Deploy script
│       └── nextjs/
│           ├── app/
│           │   ├── page.tsx                # Home - token list
│           │   ├── create/page.tsx         # Create new token
│           │   └── token/[address]/page.tsx # Token detail + trading
│           └── contracts/
│               └── externalContracts.ts    # ABIs for LaunchToken, etc.
```

---

## Key Contracts

### TokenFactory.sol

Deploys tokens and manages graduation to V2.

```solidity
// Create a new token (ERC-1167 minimal proxy)
function createToken(string name, string symbol) returns (address token)

// Create V2 pool for graduated token (anyone can call)
function createGraduatedPool(address token)
  - Uses graduationFunds[token] for ETH liquidity
  - Calculates tokens for price continuity
  - Registers token with CreatorFeeRouter
  - Stores pair address in tokenPairs[token]

// View functions
function graduationFunds(token) returns (uint256)  // ETH held for pool
function hasPair(token) returns (bool)             // V2 pair exists?
function getPair(token) returns (address)          // V2 pair address
```

### LaunchToken.sol

ERC-20 with bonding curve mechanics.

```solidity
// Trading (only works before graduation)
function buy() payable              // Buy tokens with ETH
function sell(uint256 amount)       // Sell tokens for ETH

// Estimates (view functions)
function estimateBuy(uint256 ethAmount) returns (uint256 tokens)
function estimateSell(uint256 tokenAmount) returns (uint256 eth)

// For pool creation
function getTokensForLiquidity(uint256 ethAmount) returns (uint256)
function getContractTokenBalance() returns (uint256)

// Creator actions
function withdrawTreasury()         // Withdraw bonding curve fees

// State
address public creator
uint256 public treasury            // Creator fees (from bonding curve)
uint256 public reserveBalance      // ETH for V2 liquidity (graduation metric)
bool public graduated
uint256 public launchTime          // For sniper protection calc
```

### CreatorFeeRouter.sol

Wraps V2 swaps with 2% creator fee (post-graduation).

```solidity
// Trading with fee
function buyTokensWithFee(token, minOut, deadline) payable returns (uint256)
function sellTokensWithFee(token, amount, minOut, deadline) returns (uint256)

// Fee withdrawal
function withdrawFees(token)        // Creator claims accumulated fees

// View functions
function estimateBuyOutput(token, ethIn) returns (uint256 tokens)
function estimateSellOutput(token, tokensIn) returns (uint256 eth)
function accumulatedFees(token) returns (uint256)
function getReserves(token) returns (uint256 ethReserve, uint256 tokenReserve)
```

### BondingCurveMath.sol (Constants)

```solidity
GRADUATION_THRESHOLD = 0.02 ether   // Reserve balance to graduate
COOLDOWN_PERIOD = 60 seconds        // Sniper protection duration
BUY_FEE_BPS = 100                   // 1% buy fee
SELL_FEE_BPS = 200                  // 2% sell fee
BASE_PRICE = 0.00001 ether          // Starting price per token
SLOPE = 0.000001 ether              // Price increase per token
```

---

## Development Workflow

### Start Local Environment

```bash
cd launchpad

# 1. Start Base fork (ALWAYS use fork, never yarn chain)
yarn fork --network base

# 2. Enable auto block mining (prevents timestamp drift)
cast rpc anvil_setIntervalMining 1

# 3. Deploy contracts
yarn deploy --file DeployLaunchpadFork.s.sol

# 4. Start frontend
yarn start
```

### Key Addresses (Base)

| Contract | Address |
|----------|---------|
| V2 Router | `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24` |
| V2 Factory | `0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6` |
| WETH | `0x4200000000000000000000000000000000000006` |

### After Deploy (Example Output)

```
TokenFactory deployed at: 0x25D23b63F166eC74b87b40cbCC5548D29576c56C
LaunchToken implementation at: 0x974fb78aE31079d3a44Da3791875AE6B9db63619
CreatorFeeRouter deployed at: 0x2f8a34bb1721684658827B3AA72eF8260D5bbbbB
```

---

## Testing Checklist

**ALWAYS TEST IN BROWSER** after code changes:

### Phase 1: Token Creation
- [ ] Go to `/create`, enter name/symbol
- [ ] Token appears on home page

### Phase 2: Sniper Protection (first 60s)
- [ ] Buy immediately - receive fewer tokens than expected
- [ ] Penalty decreases as time passes

### Phase 3: Normal Bonding Curve
- [ ] Wait 60s for sniper protection to end
- [ ] Buy with various amounts (0.001, 0.01 ETH)
- [ ] Verify estimates match actual tokens received
- [ ] Sell tokens - verify 2% fee applied
- [ ] Check "Reserve Balance" increases (graduation metric)
- [ ] Check "Creator Earnings" accumulates fees

### Phase 4: Graduation
- [ ] Buy until reserve reaches 0.02 ETH
- [ ] Status changes to "Graduated"
- [ ] Bonding curve buy/sell disabled

### Phase 5: V2 Pool
- [ ] Click "Create Pool" button
- [ ] Pool created with graduation funds
- [ ] Buy via CreatorFeeRouter (2% fee)
- [ ] Sell via CreatorFeeRouter (2% fee)
- [ ] Creator can withdraw V2 trading fees

### Creator Actions
- [ ] "Withdraw" button claims bonding curve treasury
- [ ] Post-graduation: withdraw fees from CreatorFeeRouter

---

## Known Behaviors

1. **Sniper protection** - First 60 seconds, buyers receive `tokens × (elapsed / 60)`. At t=0, you get 0 tokens. At t=30s, you get 50%.

2. **Price continuity** - When pool is created, the V2 starting price matches the final bonding curve price. First V2 purchase gives similar tokens to last curve purchase.

3. **Two fee systems**:
   - Bonding curve: 1% buy, 2% sell → goes to `treasury` (creator)
   - CreatorFeeRouter: 2% on both → goes to `accumulatedFees` (creator)
   - Direct V2 trading: 0% (users can bypass fees)

4. **Graduation funds flow**: When `reserveBalance >= 0.02 ETH`, the token calls `factory.receive()` sending the reserve ETH. Factory stores it in `graduationFunds[token]`.

5. **Anyone can create pool** - After graduation, anyone can call `createGraduatedPool()`. This is intentional - no admin bottleneck.

---

## Architecture Diagram

```
                                    ┌──────────────────┐
                                    │   User Wallet    │
                                    └────────┬─────────┘
                                             │
                    ┌────────────────────────┼────────────────────────┐
                    │                        │                        │
                    ▼                        ▼                        ▼
           ┌───────────────┐        ┌───────────────┐        ┌───────────────┐
           │  /create      │        │  /token/[addr]│        │  /            │
           │  Create Token │        │  Trade + Info │        │  Token List   │
           └───────┬───────┘        └───────┬───────┘        └───────────────┘
                   │                        │
                   ▼                        ▼
           ┌───────────────┐        ┌───────────────────────────────────┐
           │ TokenFactory  │        │           LaunchToken             │
           │ .createToken()│◄───────│  (before graduation)              │
           └───────────────┘        │  buy(), sell(), withdrawTreasury()│
                   │                └───────────────┬───────────────────┘
                   │                                │ graduation
                   │                                ▼
                   │                ┌───────────────────────────────────┐
                   │                │         TokenFactory              │
                   │                │    .createGraduatedPool()         │
                   │                │  - Uses graduationFunds           │
                   │                │  - Creates V2 Pair                │
                   │                │  - Registers with FeeRouter       │
                   │                └───────────────┬───────────────────┘
                   │                                │
                   ▼                                ▼
           ┌───────────────┐        ┌───────────────────────────────────┐
           │  Uniswap V2   │◄───────│       CreatorFeeRouter            │
           │  Router/Pair  │        │  (after graduation)               │
           │  (Base)       │        │  buyTokensWithFee()               │
           └───────────────┘        │  sellTokensWithFee()              │
                                    │  withdrawFees()                   │
                                    └───────────────────────────────────┘
```

---

## Quick Reference

| What | Where |
|------|-------|
| Create token | `TokenFactory.createToken()` |
| Buy on curve | `LaunchToken.buy()` |
| Sell on curve | `LaunchToken.sell(amount)` |
| Check graduation | `LaunchToken.graduated` |
| Graduation threshold | `BondingCurveMath.GRADUATION_THRESHOLD` (0.02 ETH) |
| Create V2 pool | `TokenFactory.createGraduatedPool(token)` |
| Buy post-grad | `CreatorFeeRouter.buyTokensWithFee()` |
| Sell post-grad | `CreatorFeeRouter.sellTokensWithFee()` |
| Claim curve fees | `LaunchToken.withdrawTreasury()` |
| Claim V2 fees | `CreatorFeeRouter.withdrawFees(token)` |
| Frontend trading | `app/token/[address]/page.tsx` |
| Token list | `app/page.tsx` |
| ABIs | `contracts/externalContracts.ts` |
