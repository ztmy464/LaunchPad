import { GenericContractsDeclaration } from "~~/utils/scaffold-eth/contract";

/**
 * LaunchToken ABI - used for interacting with tokens deployed by TokenFactory
 * Each token is an ERC-1167 minimal proxy to the implementation
 */
const LaunchTokenABI = [
  { type: "receive", stateMutability: "payable" },
  {
    type: "function",
    name: "name",
    inputs: [],
    outputs: [{ name: "", type: "string", internalType: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "symbol",
    inputs: [],
    outputs: [{ name: "", type: "string", internalType: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "decimals",
    inputs: [],
    outputs: [{ name: "", type: "uint8", internalType: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "totalSupply",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "buy",
    inputs: [],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "sell",
    inputs: [{ name: "tokensToSell", type: "uint256", internalType: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "getCurrentPrice",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "estimateBuy",
    inputs: [{ name: "ethAmount", type: "uint256", internalType: "uint256" }],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "estimateSell",
    inputs: [{ name: "tokensToSell", type: "uint256", internalType: "uint256" }],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "treasury",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "graduated",
    inputs: [],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "graduationProgress",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "creator",
    inputs: [],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "launchTime",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "cooldownRemaining",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isCooldownComplete",
    inputs: [],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "reserveBalance",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "expectedV2Pair",
    inputs: [],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "feeRouter",
    inputs: [],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getTokensForLiquidity",
    inputs: [{ name: "ethAmount", type: "uint256", internalType: "uint256" }],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getContractTokenBalance",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "withdrawTreasury",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "emergencyWithdraw",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "event",
    name: "TokensBought",
    inputs: [
      { name: "buyer", type: "address", indexed: true, internalType: "address" },
      { name: "ethIn", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "tokensOut", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "fee", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "TokensSold",
    inputs: [
      { name: "seller", type: "address", indexed: true, internalType: "address" },
      { name: "tokensIn", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "ethOut", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "fee", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "Graduated",
    inputs: [
      { name: "pool", type: "address", indexed: true, internalType: "address" },
      { name: "ethLiquidity", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "tokenLiquidity", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "TreasuryWithdrawn",
    inputs: [
      { name: "creator", type: "address", indexed: true, internalType: "address" },
      { name: "amount", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "EmergencyWithdraw",
    inputs: [
      { name: "creator", type: "address", indexed: true, internalType: "address" },
      { name: "ethAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "tokenAmount", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
] as const;

const externalContracts = {
  // LaunchToken is used dynamically - tokens are deployed as proxies
  // This ABI is exported for use with useContractRead/useContractWrite with dynamic addresses
} as const;

export default externalContracts satisfies GenericContractsDeclaration;

// Export LaunchToken ABI for dynamic contract interactions
export { LaunchTokenABI };

/**
 * SimplePool ABI - for trading graduated tokens
 */
export const SimplePoolABI = [
  {
    type: "function",
    name: "createPool",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "tokenAmount", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "lpTokens", type: "uint256", internalType: "uint256" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "buyTokens",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "minTokensOut", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "tokensOut", type: "uint256", internalType: "uint256" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "sellTokens",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "tokenAmount", type: "uint256", internalType: "uint256" },
      { name: "minEthOut", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "ethOut", type: "uint256", internalType: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "addLiquidity",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "minLpTokens", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "lpTokens", type: "uint256", internalType: "uint256" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "removeLiquidity",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "lpAmount", type: "uint256", internalType: "uint256" },
      { name: "minEthOut", type: "uint256", internalType: "uint256" },
      { name: "minTokensOut", type: "uint256", internalType: "uint256" },
    ],
    outputs: [
      { name: "ethOut", type: "uint256", internalType: "uint256" },
      { name: "tokensOut", type: "uint256", internalType: "uint256" },
    ],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "hasPool",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getReserves",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [
      { name: "ethReserve", type: "uint256", internalType: "uint256" },
      { name: "tokenReserve", type: "uint256", internalType: "uint256" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getPrice",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getLiquidity",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "provider", type: "address", internalType: "address" },
    ],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getTotalLiquidity",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "estimateBuyOutput",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "ethIn", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "tokensOut", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "estimateSellOutput",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "tokensIn", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "ethOut", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "estimateAddLiquidity",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "ethAmount", type: "uint256", internalType: "uint256" },
    ],
    outputs: [
      { name: "tokensRequired", type: "uint256", internalType: "uint256" },
      { name: "lpTokensOut", type: "uint256", internalType: "uint256" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "estimateRemoveLiquidity",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "lpAmount", type: "uint256", internalType: "uint256" },
    ],
    outputs: [
      { name: "ethOut", type: "uint256", internalType: "uint256" },
      { name: "tokensOut", type: "uint256", internalType: "uint256" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "tokenCreators",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "emergencyDrainPool",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "event",
    name: "PoolCreated",
    inputs: [
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "ethAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "tokenAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "lpTokens", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "Swap",
    inputs: [
      { name: "user", type: "address", indexed: true, internalType: "address" },
      { name: "isBuy", type: "bool", indexed: false, internalType: "bool" },
      { name: "amountIn", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "amountOut", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "fee", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "LiquidityAdded",
    inputs: [
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "provider", type: "address", indexed: true, internalType: "address" },
      { name: "ethAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "tokenAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "lpTokens", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "LiquidityRemoved",
    inputs: [
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "provider", type: "address", indexed: true, internalType: "address" },
      { name: "ethAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "tokenAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "lpBurned", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "EmergencyPoolDrain",
    inputs: [
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "creator", type: "address", indexed: true, internalType: "address" },
      { name: "ethAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "tokenAmount", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
] as const;

/**
 * TokenFactory ABI - for creating graduated pools (V2 version)
 */
export const TokenFactoryABI = [
  {
    type: "function",
    name: "createGraduatedPool",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "graduationFunds",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "hasPair",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getPair",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "feeRouter",
    inputs: [],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "v2Router",
    inputs: [],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "emergencyWithdrawGraduationFunds",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "event",
    name: "GraduatedPoolCreated",
    inputs: [
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "pair", type: "address", indexed: true, internalType: "address" },
      { name: "ethAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "tokenAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "liquidity", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "EmergencyGraduationWithdraw",
    inputs: [
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "creator", type: "address", indexed: true, internalType: "address" },
      { name: "amount", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "function",
    name: "rugPool",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "event",
    name: "PoolDrained",
    inputs: [
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "creator", type: "address", indexed: true, internalType: "address" },
      { name: "ethAmount", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "tokenAmount", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
] as const;

/**
 * ERC20 Approve ABI - for token approvals
 */
export const ERC20ApproveABI = [
  {
    type: "function",
    name: "approve",
    inputs: [
      { name: "spender", type: "address", internalType: "address" },
      { name: "amount", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "allowance",
    inputs: [
      { name: "owner", type: "address", internalType: "address" },
      { name: "spender", type: "address", internalType: "address" },
    ],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
] as const;

/**
 * CreatorFeeRouter ABI - for fee-wrapped V2 swaps
 */
export const CreatorFeeRouterABI = [
  {
    type: "function",
    name: "depositFees",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "buyTokensWithFee",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "minTokensOut", type: "uint256", internalType: "uint256" },
      { name: "deadline", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "tokensOut", type: "uint256", internalType: "uint256" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "sellTokensWithFee",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "tokenAmount", type: "uint256", internalType: "uint256" },
      { name: "minEthOut", type: "uint256", internalType: "uint256" },
      { name: "deadline", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "ethOut", type: "uint256", internalType: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "withdrawFees",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "hasPair",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getPair",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getReserves",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [
      { name: "ethReserve", type: "uint256", internalType: "uint256" },
      { name: "tokenReserve", type: "uint256", internalType: "uint256" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "estimateBuyOutput",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "ethIn", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "tokensOut", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "estimateSellOutput",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "tokensIn", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "ethOut", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getCreator",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isRegistered",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "accumulatedFees",
    inputs: [{ name: "token", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "FEE_BPS",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "event",
    name: "SwapWithFee",
    inputs: [
      { name: "user", type: "address", indexed: true, internalType: "address" },
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "isBuy", type: "bool", indexed: false, internalType: "bool" },
      { name: "amountIn", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "amountOut", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "fee", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "FeesWithdrawn",
    inputs: [
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "creator", type: "address", indexed: true, internalType: "address" },
      { name: "amount", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "FeesDeposited",
    inputs: [
      { name: "token", type: "address", indexed: true, internalType: "address" },
      { name: "amount", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
] as const;

/**
 * Uniswap V2 Router ABI - minimal subset for testing pool creation griefing prevention
 */
export const UniswapV2RouterABI = [
  {
    type: "function",
    name: "addLiquidityETH",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "amountTokenDesired", type: "uint256", internalType: "uint256" },
      { name: "amountTokenMin", type: "uint256", internalType: "uint256" },
      { name: "amountETHMin", type: "uint256", internalType: "uint256" },
      { name: "to", type: "address", internalType: "address" },
      { name: "deadline", type: "uint256", internalType: "uint256" },
    ],
    outputs: [
      { name: "amountToken", type: "uint256", internalType: "uint256" },
      { name: "amountETH", type: "uint256", internalType: "uint256" },
      { name: "liquidity", type: "uint256", internalType: "uint256" },
    ],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "WETH",
    inputs: [],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "factory",
    inputs: [],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
] as const;
