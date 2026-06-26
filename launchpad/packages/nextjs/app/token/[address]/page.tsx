"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { formatEther, maxUint256, parseEther } from "viem";
import { hardhat } from "viem/chains";
import { useAccount, useBalance, useReadContract, useWriteContract } from "wagmi";
import {
  ArrowLeftIcon,
  ArrowTopRightOnSquareIcon,
  ArrowsRightLeftIcon,
  BanknotesIcon,
  BeakerIcon,
  ClockIcon,
  Cog6ToothIcon,
  ExclamationTriangleIcon,
  PlusIcon,
  RocketLaunchIcon,
} from "@heroicons/react/24/outline";
import { TokenChartCard } from "~~/components/charts/TokenChartCard";
import { RecentTradesPanel } from "~~/components/market/RecentTradesPanel";
import {
  CreatorFeeRouterABI,
  ERC20ApproveABI,
  LaunchTokenABI,
  TokenFactoryABI,
  UniswapV2RouterABI,
} from "~~/contracts/externalContracts";
import { useDeployedContractInfo, useTargetNetwork } from "~~/hooks/scaffold-eth";
import { useTokenMarketData } from "~~/hooks/useTokenMarketData";
import { buildDemoCandles } from "~~/utils/marketData";
import { notification } from "~~/utils/scaffold-eth";

const SLIPPAGE_OPTIONS = [0.5, 1, 3, 5];

// Pool Swap Interface Component for Graduated Tokens (V2 + Fee Router)
const PoolSwapInterface = ({
  tokenAddress,
  symbol,
  userBalance,
  refetchAllData,
}: {
  tokenAddress: `0x${string}`;
  symbol: string;
  userBalance: bigint | undefined;
  refetchAllData: () => void;
}) => {
  const { address: userAddress, isConnected } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const [swapTab, setSwapTab] = useState<"buy" | "sell">("buy");
  const [swapAmount, setSwapAmount] = useState("0.0001");
  const [isSwapping, setIsSwapping] = useState(false);

  // Get CreatorFeeRouter address
  const { data: feeRouterInfo } = useDeployedContractInfo({ contractName: "CreatorFeeRouter" });
  const feeRouterAddress = feeRouterInfo?.address;

  // Get TokenFactory address for creating graduated pools
  const { data: tokenFactoryInfo } = useDeployedContractInfo({ contractName: "TokenFactory" });
  const tokenFactoryAddress = tokenFactoryInfo?.address;

  const { data: ethBalance, refetch: refetchEthBalance } = useBalance({
    address: userAddress,
    query: { refetchInterval: 3000 },
  });

  // Read graduation funds from factory
  const { data: graduationFunds, refetch: refetchGraduationFunds } = useReadContract({
    address: tokenFactoryAddress,
    abi: TokenFactoryABI,
    functionName: "graduationFunds",
    args: [tokenAddress],
    query: { enabled: !!tokenFactoryAddress, refetchInterval: 3000 },
  });

  // Check if V2 pair exists via factory
  const { data: hasPair, refetch: refetchHasPair } = useReadContract({
    address: tokenFactoryAddress,
    abi: TokenFactoryABI,
    functionName: "hasPair",
    args: [tokenAddress],
    query: { enabled: !!tokenFactoryAddress, refetchInterval: 3000 },
  });

  // Get pair address
  const { data: pairAddress } = useReadContract({
    address: tokenFactoryAddress,
    abi: TokenFactoryABI,
    functionName: "getPair",
    args: [tokenAddress],
    query: { enabled: !!tokenFactoryAddress && !!hasPair, refetchInterval: 3000 },
  });

  // Get pool reserves via fee router
  const { data: reserves, refetch: refetchReserves } = useReadContract({
    address: feeRouterAddress,
    abi: CreatorFeeRouterABI,
    functionName: "getReserves",
    args: [tokenAddress],
    query: { enabled: !!feeRouterAddress && !!hasPair, refetchInterval: 3000 },
  });

  // Estimate buy output
  const buyAmountWei = swapTab === "buy" && swapAmount ? parseEther(swapAmount) : 0n;
  const { data: estimatedBuyTokens } = useReadContract({
    address: feeRouterAddress,
    abi: CreatorFeeRouterABI,
    functionName: "estimateBuyOutput",
    args: [tokenAddress, buyAmountWei],
    query: { enabled: !!feeRouterAddress && !!hasPair && buyAmountWei > 0n },
  });

  // Estimate sell output
  const sellAmountWei = swapTab === "sell" && swapAmount ? parseEther(swapAmount) : 0n;
  const { data: estimatedSellEth } = useReadContract({
    address: feeRouterAddress,
    abi: CreatorFeeRouterABI,
    functionName: "estimateSellOutput",
    args: [tokenAddress, sellAmountWei],
    query: { enabled: !!feeRouterAddress && !!hasPair && sellAmountWei > 0n },
  });

  // Check token allowance for FeeRouter
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: tokenAddress,
    abi: ERC20ApproveABI,
    functionName: "allowance",
    args: [userAddress || "0x0", feeRouterAddress || "0x0"],
    query: { enabled: !!userAddress && !!feeRouterAddress },
  });

  const { writeContractAsync } = useWriteContract();

  // Helper to refetch data
  const refetchSwapData = () => {
    refetchReserves();
    refetchEthBalance();
    refetchAllData();
  };

  // Create V2 Pool using factory's graduation funds
  const handleCreatePool = async () => {
    if (!tokenFactoryAddress) {
      notification.error("TokenFactory not deployed");
      return;
    }

    if (!graduationFunds || graduationFunds === 0n) {
      notification.error("No graduation funds available. Token may not have graduated properly.");
      return;
    }

    setIsSwapping(true);
    try {
      notification.info("Creating Uniswap V2 pool...");
      await writeContractAsync({
        address: tokenFactoryAddress,
        abi: TokenFactoryABI,
        functionName: "createGraduatedPool",
        args: [tokenAddress],
      });

      notification.success("V2 Pool created! Token is now tradeable everywhere.");
      refetchHasPair();
      refetchReserves();
      refetchGraduationFunds();
      refetchAllData();
    } catch (error: any) {
      notification.error(error.message || "Failed to create pool");
    } finally {
      setIsSwapping(false);
    }
  };

  // Buy tokens via FeeRouter
  const handleBuy = async () => {
    if (!feeRouterAddress || !swapAmount) {
      notification.error("Please enter an amount");
      return;
    }

    setIsSwapping(true);
    try {
      const ethAmount = parseEther(swapAmount);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 300); // 5 min deadline

      await writeContractAsync({
        address: feeRouterAddress,
        abi: CreatorFeeRouterABI,
        functionName: "buyTokensWithFee",
        args: [tokenAddress, 0n, deadline], // 0 minOut for testing
        value: ethAmount,
      });

      notification.success("Buy successful! 2% fee collected for creator.");
      setSwapAmount("");
      refetchSwapData();
    } catch (error: any) {
      notification.error(error.message || "Buy failed");
    } finally {
      setIsSwapping(false);
    }
  };

  // Sell tokens via FeeRouter
  const handleSell = async () => {
    if (!feeRouterAddress || !swapAmount) {
      notification.error("Please enter an amount");
      return;
    }

    setIsSwapping(true);
    try {
      const tokenAmount = parseEther(swapAmount);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 300); // 5 min deadline

      // Approve if needed
      if ((allowance || 0n) < tokenAmount) {
        notification.info("Approving tokens...");
        await writeContractAsync({
          address: tokenAddress,
          abi: ERC20ApproveABI,
          functionName: "approve",
          args: [feeRouterAddress, maxUint256],
        });
        await refetchAllowance();
      }

      await writeContractAsync({
        address: feeRouterAddress,
        abi: CreatorFeeRouterABI,
        functionName: "sellTokensWithFee",
        args: [tokenAddress, tokenAmount, 0n, deadline], // 0 minOut for testing
      });

      notification.success("Sell successful! 2% fee collected for creator.");
      setSwapAmount("");
      refetchSwapData();
    } catch (error: any) {
      notification.error(error.message || "Sell failed");
    } finally {
      setIsSwapping(false);
    }
  };

  // If FeeRouter not deployed
  if (!feeRouterAddress) {
    return (
      <div className="space-y-4">
        <div className="alert alert-success">
          <RocketLaunchIcon className="w-5 h-5" />
          <div>
            <div className="font-semibold">Graduated!</div>
            <div className="text-sm">Fee Router not deployed yet.</div>
          </div>
        </div>
      </div>
    );
  }

  // If pool doesn't exist yet
  if (!hasPair) {
    return (
      <div className="space-y-4">
        <div className="alert alert-success">
          <RocketLaunchIcon className="w-5 h-5" />
          <div>
            <div className="font-semibold">Graduated!</div>
            <div className="text-sm">Create a Uniswap V2 pool to enable trading everywhere.</div>
          </div>
        </div>

        {/* Show graduation funds info */}
        {graduationFunds && graduationFunds > 0n && (
          <div className="bg-base-200 rounded-lg p-3">
            <div className="text-xs text-base-content/60 mb-1">Graduation Funds Available</div>
            <div className="font-mono font-semibold text-primary">{formatEther(graduationFunds)} ETH</div>
            <div className="text-xs text-base-content/50 mt-1">
              Will create a Uniswap V2 pool at the final bonding curve price
            </div>
          </div>
        )}

        {isConnected ? (
          <>
            <button
              className="btn btn-primary w-full gap-2"
              onClick={handleCreatePool}
              disabled={isSwapping || !graduationFunds || graduationFunds === 0n}
            >
              {isSwapping ? (
                <>
                  <span className="loading loading-spinner"></span>
                  Creating V2 Pool...
                </>
              ) : (
                <>
                  <PlusIcon className="w-5 h-5" />
                  Create Uniswap V2 Pool
                </>
              )}
            </button>
            <p className="text-xs text-center text-base-content/60">
              Creates a real Uniswap V2 pool. Token will be tradeable on Uniswap, Rainbow, and all DEX aggregators!
            </p>
          </>
        ) : (
          <div className="alert alert-warning">Connect wallet to create pool</div>
        )}
      </div>
    );
  }

  // Pool exists - show swap interface
  const [ethReserve, tokenReserve] = reserves || [0n, 0n];

  // Build Uniswap URL
  const getUniswapUrl = () => {
    const chainNames: Record<number, string> = {
      1: "ethereum",
      8453: "base",
      10: "optimism",
      42161: "arbitrum",
      137: "polygon",
      31337: "base", // Local fork shows as base
    };
    const chainName = chainNames[targetNetwork.id];
    if (!chainName) return null;
    return `https://app.uniswap.org/swap?chain=${chainName}&inputCurrency=ETH&outputCurrency=${tokenAddress}`;
  };

  const uniswapUrl = getUniswapUrl();

  return (
    <div className="space-y-4">
      <div className="alert alert-success">
        <RocketLaunchIcon className="w-5 h-5" />
        <div className="flex-1">
          <div className="font-semibold">Trading on Uniswap V2!</div>
          <div className="text-sm">2% creator fee when trading here</div>
        </div>
        {uniswapUrl && (
          <a
            href={uniswapUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="btn btn-sm btn-ghost gap-1"
            title="Trade without creator fee on Uniswap"
          >
            <ArrowTopRightOnSquareIcon className="w-4 h-4" />
            Uniswap
          </a>
        )}
      </div>

      {/* Pool Stats */}
      <div className="bg-base-200 rounded-lg p-3">
        <div className="flex justify-between items-center mb-1">
          <div className="text-xs text-base-content/60">V2 Pool Reserves</div>
          {pairAddress && (
            <a
              href={`https://basescan.org/address/${pairAddress}`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-xs text-primary hover:underline"
            >
              View Pair
            </a>
          )}
        </div>
        <div className="grid grid-cols-2 gap-2 text-sm font-mono">
          <div>{formatEther(ethReserve).slice(0, 8)} ETH</div>
          <div>
            {Number(tokenReserve / BigInt(1e18)).toLocaleString()} {symbol}
          </div>
        </div>
      </div>

      {/* Trading notice */}
      <div className="bg-base-200/50 rounded-lg p-2 text-xs text-center text-base-content/60">
        Trade here = 2% creator fee | Trade on Uniswap = no creator fee (just 0.3% LP fee)
      </div>

      {!isConnected ? (
        <div className="alert alert-warning">Connect wallet to trade</div>
      ) : (
        <>
          {/* Swap Tabs */}
          <div className="flex gap-2">
            <button
              className={`flex-1 py-3 px-4 rounded-lg font-semibold text-lg transition-all ${
                swapTab === "buy"
                  ? "bg-primary text-primary-content shadow-lg"
                  : "bg-base-200 text-base-content/60 hover:bg-base-300"
              }`}
              onClick={() => {
                setSwapTab("buy");
                setSwapAmount("");
              }}
            >
              Buy
            </button>
            <button
              className={`flex-1 py-3 px-4 rounded-lg font-semibold text-lg transition-all ${
                swapTab === "sell"
                  ? "bg-secondary text-secondary-content shadow-lg"
                  : "bg-base-200 text-base-content/60 hover:bg-base-300"
              }`}
              onClick={() => {
                setSwapTab("sell");
                setSwapAmount("");
              }}
            >
              Sell
            </button>
          </div>

          {/* Amount Input */}
          <div className="form-control">
            <label className="label">
              <span className="label-text">{swapTab === "buy" ? "ETH Amount" : "Token Amount"}</span>
              <span className="label-text-alt">
                {swapTab === "buy"
                  ? `Balance: ${ethBalance ? formatEther(ethBalance.value).slice(0, 8) : "0"} ETH`
                  : `Balance: ${userBalance ? Number(userBalance / BigInt(1e18)).toLocaleString() : "0"}`}
              </span>
            </label>
            <input
              type="number"
              placeholder="0.0"
              className="input input-bordered w-full font-mono"
              value={swapAmount}
              onChange={e => setSwapAmount(e.target.value)}
              disabled={isSwapping}
              step="0.001"
              min="0"
            />
          </div>

          {/* Quick Amount Buttons */}
          <div className="flex gap-2">
            {swapTab === "buy" ? (
              <>
                <button className="btn btn-xs btn-outline" onClick={() => setSwapAmount("0.0001")}>
                  0.0001
                </button>
                <button className="btn btn-xs btn-outline" onClick={() => setSwapAmount("0.001")}>
                  0.001
                </button>
                <button className="btn btn-xs btn-outline" onClick={() => setSwapAmount("0.01")}>
                  0.01
                </button>
              </>
            ) : (
              <>
                <button
                  className="btn btn-xs btn-outline"
                  onClick={() => userBalance && setSwapAmount(formatEther(userBalance / 4n))}
                >
                  25%
                </button>
                <button
                  className="btn btn-xs btn-outline"
                  onClick={() => userBalance && setSwapAmount(formatEther(userBalance / 2n))}
                >
                  50%
                </button>
                <button
                  className="btn btn-xs btn-outline"
                  onClick={() => userBalance && setSwapAmount(formatEther(userBalance))}
                >
                  Max
                </button>
              </>
            )}
          </div>

          {/* Estimate */}
          <div className="bg-base-200 rounded-lg p-3">
            <div className="text-sm text-base-content/60">You will receive (approx)</div>
            <div className="font-mono font-semibold text-lg">
              {swapTab === "buy"
                ? `${estimatedBuyTokens !== undefined ? (Number(estimatedBuyTokens) / 1e18).toFixed(4) : "0"} ${symbol}`
                : `${
                    estimatedSellEth !== undefined
                      ? Number(formatEther(estimatedSellEth))
                          .toFixed(10)
                          .replace(/\.?0+$/, "")
                      : "0"
                  } ETH`}
            </div>
            <div className="text-xs text-base-content/60 mt-1">2% creator fee included</div>
          </div>

          {/* Action Button */}
          <button
            className={`btn btn-lg w-full ${swapTab === "buy" ? "btn-primary" : "btn-secondary"}`}
            onClick={swapTab === "buy" ? handleBuy : handleSell}
            disabled={isSwapping || !swapAmount || parseFloat(swapAmount) <= 0}
          >
            {isSwapping ? (
              <>
                <span className="loading loading-spinner"></span>
                Swapping...
              </>
            ) : swapTab === "buy" ? (
              `Buy ${symbol}`
            ) : (
              `Sell ${symbol}`
            )}
          </button>
        </>
      )}
    </div>
  );
};

const TokenPage: NextPage = () => {
  const params = useParams();
  const tokenAddress = params.address as `0x${string}`;
  const { address: userAddress, isConnected } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const [activeTab, setActiveTab] = useState<"buy" | "sell">("buy");
  const [amount, setAmount] = useState("0.0001");
  const [isTransacting, setIsTransacting] = useState(false);
  const [isWithdrawing, setIsWithdrawing] = useState(false);
  const [isWithdrawingFees, setIsWithdrawingFees] = useState(false);
  const [showRugModal, setShowRugModal] = useState(false);
  const [isRugging, setIsRugging] = useState(false);
  const [isTestingLiquidity, setIsTestingLiquidity] = useState(false);
  const [showSlippageSettings, setShowSlippageSettings] = useState(false);
  const [slippagePercent, setSlippagePercent] = useState(1);

  // Token data reads with auto-refresh
  const { data: name } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "name",
  });

  const { data: symbol } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "symbol",
  });

  const { data: totalSupply, refetch: refetchTotalSupply } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "totalSupply",
    query: { refetchInterval: 3000 },
  });

  const { data: currentPrice, refetch: refetchPrice } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "getCurrentPrice",
    query: { refetchInterval: 3000 },
  });

  const demoCandles = useMemo(
    () => buildDemoCandles({ tokenAddress, currentPrice: currentPrice as bigint | undefined }),
    [currentPrice, tokenAddress],
  );
  const {
    candles: marketCandles,
    trades: recentTrades,
    isLoading: isMarketLoading,
    isLive: isMarketLive,
    refetchMarketData,
  } = useTokenMarketData(tokenAddress);
  const chartCandles = marketCandles.length >= 2 ? marketCandles : demoCandles;

  const { data: treasury, refetch: refetchTreasury } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "treasury",
    query: { refetchInterval: 3000 },
  });

  const { data: reserveBalance, refetch: refetchReserveBalance } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "reserveBalance",
    query: { refetchInterval: 3000 },
  });

  const { data: graduated, refetch: refetchGraduated } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "graduated",
    query: { refetchInterval: 3000 },
  });

  const { data: creator } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "creator",
  });

  const { data: cooldownRemaining } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "cooldownRemaining",
    query: { refetchInterval: 1000 },
  });

  // Read expected V2 pair address (for security test)
  const { data: expectedV2Pair } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "expectedV2Pair",
  });

  // Read config values from TokenFactory (uses deployed contract info)
  const { data: tokenFactoryInfo } = useDeployedContractInfo({ contractName: "TokenFactory" });
  const tokenFactoryAddress = tokenFactoryInfo?.address;

  // Read CreatorFeeRouter info
  const { data: feeRouterInfo } = useDeployedContractInfo({ contractName: "CreatorFeeRouter" });
  const feeRouterAddress = feeRouterInfo?.address;

  // Read graduation funds from factory (for post-graduation rug)
  const { data: graduationFunds, refetch: refetchGraduationFunds } = useReadContract({
    address: tokenFactoryAddress,
    abi: TokenFactoryABI,
    functionName: "graduationFunds",
    args: [tokenAddress],
    query: { enabled: !!tokenFactoryAddress, refetchInterval: 3000 },
  });

  // Read V2 Router address from factory (for security test)
  const { data: v2RouterAddress } = useReadContract({
    address: tokenFactoryAddress,
    abi: TokenFactoryABI,
    functionName: "v2Router",
    query: { enabled: !!tokenFactoryAddress },
  });

  // Check if V2 pair exists via factory
  const { data: hasPool, refetch: refetchHasPool } = useReadContract({
    address: tokenFactoryAddress,
    abi: TokenFactoryABI,
    functionName: "hasPair",
    args: [tokenAddress],
    query: { enabled: !!tokenFactoryAddress, refetchInterval: 3000 },
  });

  // Get pool reserves via fee router (for display)
  const { data: poolReserves, refetch: refetchPoolReserves } = useReadContract({
    address: feeRouterAddress,
    abi: CreatorFeeRouterABI,
    functionName: "getReserves",
    args: [tokenAddress],
    query: { enabled: !!feeRouterAddress && !!hasPool, refetchInterval: 3000 },
  });

  // Get token creator from fee router
  const { data: poolCreator } = useReadContract({
    address: feeRouterAddress,
    abi: CreatorFeeRouterABI,
    functionName: "getCreator",
    args: [tokenAddress],
    query: { enabled: !!feeRouterAddress && !!hasPool },
  });

  // Get accumulated fees from CreatorFeeRouter (unified fee tracking)
  const { data: accumulatedFees, refetch: refetchAccumulatedFees } = useReadContract({
    address: feeRouterAddress,
    abi: CreatorFeeRouterABI,
    functionName: "accumulatedFees",
    args: [tokenAddress],
    query: { enabled: !!feeRouterAddress, refetchInterval: 3000 },
  });

  // Check if token is registered with fee router
  const { data: isTokenRegistered } = useReadContract({
    address: feeRouterAddress,
    abi: CreatorFeeRouterABI,
    functionName: "isRegistered",
    args: [tokenAddress],
    query: { enabled: !!feeRouterAddress },
  });

  const { data: graduationThreshold } = useReadContract({
    address: tokenFactoryInfo?.address,
    abi: [
      {
        type: "function",
        name: "getGraduationThreshold",
        inputs: [],
        outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
        stateMutability: "pure",
      },
    ] as const,
    functionName: "getGraduationThreshold",
    query: { enabled: !!tokenFactoryInfo?.address },
  });

  const { data: buyFeeBps } = useReadContract({
    address: tokenFactoryInfo?.address,
    abi: [
      {
        type: "function",
        name: "getBuyFeeBps",
        inputs: [],
        outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
        stateMutability: "pure",
      },
    ] as const,
    functionName: "getBuyFeeBps",
    query: { enabled: !!tokenFactoryInfo?.address },
  });

  const { data: sellFeeBps } = useReadContract({
    address: tokenFactoryInfo?.address,
    abi: [
      {
        type: "function",
        name: "getSellFeeBps",
        inputs: [],
        outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
        stateMutability: "pure",
      },
    ] as const,
    functionName: "getSellFeeBps",
    query: { enabled: !!tokenFactoryInfo?.address },
  });

  const { data: userBalance, refetch: refetchUserBalance } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "balanceOf",
    args: [userAddress || "0x0"],
    query: { enabled: !!userAddress, refetchInterval: 3000 },
  });

  const { data: ethBalance, refetch: refetchEthBalance } = useBalance({
    address: userAddress,
    query: { refetchInterval: 3000 },
  });

  // Helper to refetch all token data
  const refetchAllData = () => {
    refetchTotalSupply();
    refetchPrice();
    refetchTreasury();
    refetchReserveBalance();
    refetchGraduated();
    refetchUserBalance();
    refetchEthBalance();
    refetchGraduationFunds();
    refetchHasPool();
    refetchPoolReserves();
    refetchAccumulatedFees();
  };

  // Estimate functions
  const ethAmountWei = amount ? parseEther(amount) : 0n;
  const tokenAmountWei = amount ? parseEther(amount) : 0n;

  const { data: estimatedTokens } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "estimateBuy",
    args: [ethAmountWei],
    query: { enabled: activeTab === "buy" && ethAmountWei > 0n, refetchInterval: 1000 },
  });

  const { data: estimatedEth } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "estimateSell",
    args: [tokenAmountWei],
    query: { enabled: activeTab === "sell" && tokenAmountWei > 0n, refetchInterval: 1000 },
  });

  // Write functions
  const { writeContractAsync } = useWriteContract();

  const handleBuy = async () => {
    if (!amount || parseFloat(amount) <= 0) {
      notification.error("Please enter an amount");
      return;
    }

    setIsTransacting(true);
    try {
      await writeContractAsync({
        address: tokenAddress,
        abi: LaunchTokenABI,
        functionName: "buy",
        value: parseEther(amount),
      });
      notification.success("Purchase successful!");
      setAmount("");
      setTimeout(() => {
        refetchAllData();
        refetchMarketData();
      }, 1500);
    } catch (error: any) {
      notification.error(error.message || "Transaction failed");
    } finally {
      setIsTransacting(false);
    }
  };

  const handleSell = async () => {
    if (!amount || parseFloat(amount) <= 0) {
      notification.error("Please enter an amount");
      return;
    }

    setIsTransacting(true);
    try {
      await writeContractAsync({
        address: tokenAddress,
        abi: LaunchTokenABI,
        functionName: "sell",
        args: [parseEther(amount)],
      });
      notification.success("Sale successful!");
      setAmount("");
      setTimeout(() => {
        refetchAllData();
        refetchMarketData();
      }, 1500);
    } catch (error: any) {
      notification.error(error.message || "Transaction failed");
    } finally {
      setIsTransacting(false);
    }
  };

  const handleWithdrawTreasury = async () => {
    if (!treasury || treasury === 0n) {
      notification.error("No earnings to withdraw");
      return;
    }

    setIsWithdrawing(true);
    try {
      await writeContractAsync({
        address: tokenAddress,
        abi: LaunchTokenABI,
        functionName: "withdrawTreasury",
      });
      notification.success("Earnings withdrawn successfully!");
      setTimeout(refetchAllData, 500);
    } catch (error: any) {
      notification.error(error.message || "Withdrawal failed");
    } finally {
      setIsWithdrawing(false);
    }
  };

  // Withdraw accumulated fees from CreatorFeeRouter
  const handleWithdrawFees = async () => {
    if (!feeRouterAddress) return;
    if (!accumulatedFees || accumulatedFees === 0n) {
      notification.error("No fees to withdraw");
      return;
    }

    setIsWithdrawingFees(true);
    try {
      await writeContractAsync({
        address: feeRouterAddress,
        abi: CreatorFeeRouterABI,
        functionName: "withdrawFees",
        args: [tokenAddress],
      });
      notification.success("Fees withdrawn successfully!");
      setTimeout(refetchAllData, 500);
    } catch (error: any) {
      notification.error(error.message || "Failed to withdraw fees");
    } finally {
      setIsWithdrawingFees(false);
    }
  };

  // Rug handler - drains all funds based on token phase
  const handleRug = async () => {
    setIsRugging(true);
    try {
      if (!graduated) {
        // Pre-graduation: drain bonding curve
        await writeContractAsync({
          address: tokenAddress,
          abi: LaunchTokenABI,
          functionName: "emergencyWithdraw",
        });
        notification.success("Emergency withdraw successful! Bonding curve drained.");
      } else if (graduationFunds && graduationFunds > 0n) {
        // Post-graduation waiting: drain graduation funds from factory
        if (!tokenFactoryAddress) {
          notification.error("Factory address not found");
          return;
        }
        await writeContractAsync({
          address: tokenFactoryAddress,
          abi: TokenFactoryABI,
          functionName: "emergencyWithdrawGraduationFunds",
          args: [tokenAddress],
        });
        notification.success("Graduation funds drained!");
      } else if (hasPool) {
        // V2 Pool active: drain the pool liquidity
        if (!tokenFactoryAddress) {
          notification.error("Factory address not found");
          return;
        }
        await writeContractAsync({
          address: tokenFactoryAddress,
          abi: TokenFactoryABI,
          functionName: "rugPool",
          args: [tokenAddress],
        });
        notification.success("Pool rugged! Liquidity drained to creator.");
      } else {
        notification.error("No funds to rug");
      }

      setShowRugModal(false);
      setTimeout(() => {
        refetchAllData();
        refetchGraduationFunds();
        refetchHasPool();
        refetchPoolReserves();
      }, 500);
    } catch (error: any) {
      notification.error(error.message || "Rug failed");
    } finally {
      setIsRugging(false);
    }
  };

  // Test function to verify V2 pair transfer blocking
  const handleTestAddLiquidity = async () => {
    if (!userBalance || userBalance === 0n) {
      notification.error("You need some tokens to test");
      return;
    }
    if (!v2RouterAddress) {
      notification.error("V2 Router not configured");
      return;
    }

    setIsTestingLiquidity(true);
    try {
      // First approve V2 Router to spend tokens
      const testTokenAmount = userBalance / 10n; // Use 10% of balance
      notification.info("Approving tokens for V2 Router...");

      await writeContractAsync({
        address: tokenAddress,
        abi: ERC20ApproveABI,
        functionName: "approve",
        args: [v2RouterAddress, testTokenAmount],
      });

      notification.info("Attempting to add liquidity (this should fail before graduation)...");

      const deadline = BigInt(Math.floor(Date.now() / 1000) + 300);

      // This should fail with TransferToPoolBlocked error if security fix is working
      await writeContractAsync({
        address: v2RouterAddress as `0x${string}`,
        abi: UniswapV2RouterABI,
        functionName: "addLiquidityETH",
        args: [tokenAddress, testTokenAmount, 0n, 0n, userAddress!, deadline],
        value: parseEther("0.0001"),
      });

      // If we get here, the security fix is NOT working
      notification.error("SECURITY ISSUE: Transfer to V2 pair was NOT blocked!");
    } catch (error: any) {
      // Check if the error is the expected TransferToPoolBlocked error
      if (error.message?.includes("TransferToPoolBlocked") || error.message?.includes("execution reverted")) {
        notification.success("Security test PASSED! Transfer to V2 pair was correctly blocked.");
      } else {
        notification.warning(`Test result: ${error.message}`);
      }
    } finally {
      setIsTestingLiquidity(false);
    }
  };

  // Check if current user is the creator
  const isCreator = userAddress && creator && userAddress.toLowerCase() === creator.toLowerCase();

  // Calculate graduation progress using dynamic threshold from contract
  const progressPercent =
    reserveBalance && graduationThreshold && graduationThreshold > 0n
      ? Number((reserveBalance * 100n) / graduationThreshold)
      : 0;

  // Calculate fee percentages for display
  const buyFeePercent = buyFeeBps ? Number(buyFeeBps) / 100 : 1;
  const sellFeePercent = sellFeeBps ? Number(sellFeeBps) / 100 : 2;
  const minimumReceived = useMemo(() => {
    if (activeTab === "buy") {
      if (estimatedTokens === undefined) return null;
      return Number(formatEther(estimatedTokens)) * (1 - slippagePercent / 100);
    }

    if (estimatedEth === undefined) return null;
    return Number(formatEther(estimatedEth)) * (1 - slippagePercent / 100);
  }, [activeTab, estimatedEth, estimatedTokens, slippagePercent]);

  return (
    <div className="container mx-auto px-6 py-8 max-w-4xl">
      <Link href="/" className="btn btn-ghost btn-sm gap-2 mb-6">
        <ArrowLeftIcon className="w-4 h-4" />
        Back to Tokens
      </Link>

      <div className="flex flex-col gap-6">
        {/* Token Info Card */}
        <div className="space-y-6">
          <div className="card bg-base-100 shadow-xl">
            <div className="card-body">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-4">
                  <div className="w-16 h-16 bg-gradient-to-br from-primary to-secondary rounded-full flex items-center justify-center text-white text-2xl font-bold">
                    {symbol?.charAt(0) || "?"}
                  </div>
                  <div>
                    <h1 className="text-3xl font-bold">{name || "Loading..."}</h1>
                    <p className="text-xl text-base-content/60 font-mono">${symbol || "..."}</p>
                  </div>
                </div>
                {graduated ? (
                  <div className="badge badge-success badge-lg gap-2">
                    <RocketLaunchIcon className="w-4 h-4" />
                    Graduated
                  </div>
                ) : (
                  <div className="badge badge-warning badge-lg">Bonding Curve</div>
                )}
              </div>

              <div className="divider"></div>

              <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
                <div className="bg-base-200 rounded-lg p-3">
                  <div className="text-xs text-base-content/60">Price</div>
                  <div className="font-mono font-semibold">{currentPrice ? formatEther(currentPrice) : "0"} ETH</div>
                </div>
                <div className="bg-base-200 rounded-lg p-3">
                  <div className="text-xs text-base-content/60">Supply</div>
                  <div className="font-mono font-semibold">
                    {totalSupply ? (Number(totalSupply) / 1e18).toFixed(4) : "0"}
                  </div>
                </div>
                <div className="bg-base-200 rounded-lg p-3">
                  <div className="text-xs text-base-content/60">Your Balance</div>
                  <div className="font-mono font-semibold">
                    {userBalance ? (Number(userBalance) / 1e18).toFixed(4) : "0"}
                  </div>
                </div>
              </div>

              {/* Reserve & Fees - show both values */}
              <div className="grid grid-cols-2 gap-4 mt-4">
                <div className="bg-base-200 rounded-lg p-3">
                  <div className="text-xs text-base-content/60">Bonding Curve Reserve</div>
                  <div className="font-mono font-semibold text-primary">
                    {reserveBalance ? formatEther(reserveBalance) : "0"} ETH
                  </div>
                  <div className="text-xs text-base-content/50 mt-1">Used for V2 liquidity at graduation</div>
                </div>
                <div className="bg-gradient-to-br from-success/10 to-primary/10 rounded-lg p-3 border border-success/20">
                  <div className="text-xs text-base-content/60">Creator Fees</div>
                  <div className="font-mono font-semibold text-success">
                    {accumulatedFees ? formatEther(accumulatedFees) : "0"} ETH
                  </div>
                  <div className="text-xs text-base-content/50 mt-1">
                    From {buyFeePercent}% buy / {sellFeePercent}% sell fees
                  </div>
                  {isCreator && accumulatedFees && accumulatedFees > 0n && (
                    <button
                      className="btn btn-success btn-xs mt-2 gap-1"
                      onClick={handleWithdrawFees}
                      disabled={isWithdrawingFees}
                    >
                      {isWithdrawingFees ? (
                        <span className="loading loading-spinner loading-xs"></span>
                      ) : (
                        <BanknotesIcon className="w-3 h-3" />
                      )}
                      Withdraw
                    </button>
                  )}
                  {/* Legacy treasury withdrawal for old tokens */}
                  {isCreator && treasury && treasury > 0n && (
                    <div className="mt-2 pt-2 border-t border-base-300">
                      <div className="text-xs text-base-content/50">Legacy fees: {formatEther(treasury)} ETH</div>
                      <button
                        className="btn btn-outline btn-xs mt-1 gap-1"
                        onClick={handleWithdrawTreasury}
                        disabled={isWithdrawing}
                      >
                        {isWithdrawing ? (
                          <span className="loading loading-spinner loading-xs"></span>
                        ) : (
                          <BanknotesIcon className="w-3 h-3" />
                        )}
                        Withdraw Legacy
                      </button>
                    </div>
                  )}
                </div>
              </div>

              {!graduated && (
                <div className="mt-4">
                  <div className="flex justify-between text-sm mb-2">
                    <span className="font-semibold">Progress to Graduation</span>
                    <span>{Math.min(progressPercent, 100).toFixed(1)}%</span>
                  </div>
                  <progress
                    className="progress progress-primary w-full h-4"
                    value={Math.min(progressPercent, 100)}
                    max="100"
                  />
                  <div className="flex justify-between text-xs text-base-content/60 mt-1">
                    <span>{reserveBalance ? formatEther(reserveBalance) : "0"} ETH in reserve</span>
                    <span>{graduationThreshold ? formatEther(graduationThreshold) : "..."} ETH to graduate</span>
                  </div>
                </div>
              )}

              {cooldownRemaining !== undefined && cooldownRemaining > 0n && (
                <div className="alert alert-warning mt-4">
                  <ClockIcon className="w-5 h-5" />
                  <div>
                    <div className="font-semibold">Sniper Protection Active</div>
                    <div className="text-sm">
                      {Number(cooldownRemaining)}s remaining. Buying now gives you proportionally fewer tokens.
                    </div>
                  </div>
                </div>
              )}

              <div className="mt-4 flex items-center gap-2 text-sm">
                <span className="text-base-content/60">Created by:</span>
                <Address
                  address={creator}
                  chain={targetNetwork}
                  blockExplorerAddressLink={
                    targetNetwork.id === hardhat.id ? `/blockexplorer/address/${creator}` : undefined
                  }
                />
              </div>
            </div>
          </div>
        </div>

        <TokenChartCard
          candles={chartCandles}
          isLoading={isMarketLoading && chartCandles.length === 0}
          watermark={symbol || "TOKEN"}
        />

        {/* Trade Card */}
        <div className="card bg-base-100 shadow-xl">
          <div className="card-body">
            <div className="flex items-center justify-between gap-3">
              <h2 className="card-title">
                <ArrowsRightLeftIcon className="w-5 h-5" />
                Trade
              </h2>
              {!graduated && (
                <button className="btn btn-sm btn-outline gap-2" onClick={() => setShowSlippageSettings(true)}>
                  <Cog6ToothIcon className="w-4 h-4" />
                  Slippage {slippagePercent}%
                </button>
              )}
            </div>

            {graduated ? (
              <PoolSwapInterface
                tokenAddress={tokenAddress}
                symbol={symbol || "TOKEN"}
                userBalance={userBalance}
                refetchAllData={refetchAllData}
              />
            ) : !isConnected ? (
              <div className="alert alert-warning">
                <span>Connect wallet to trade</span>
              </div>
            ) : (
              <>
                <div className="flex gap-2 mb-4">
                  <button
                    className={`flex-1 py-3 px-4 rounded-lg font-semibold text-lg transition-all ${
                      activeTab === "buy"
                        ? "bg-primary text-primary-content shadow-lg"
                        : "bg-base-200 text-base-content/60 hover:bg-base-300"
                    }`}
                    onClick={() => {
                      setActiveTab("buy");
                      setAmount("");
                    }}
                  >
                    Buy
                  </button>
                  <button
                    className={`flex-1 py-3 px-4 rounded-lg font-semibold text-lg transition-all ${
                      activeTab === "sell"
                        ? "bg-secondary text-secondary-content shadow-lg"
                        : "bg-base-200 text-base-content/60 hover:bg-base-300"
                    }`}
                    onClick={() => {
                      setActiveTab("sell");
                      setAmount("");
                    }}
                  >
                    Sell
                  </button>
                </div>

                <div className="form-control">
                  <label className="label">
                    <span className="label-text">{activeTab === "buy" ? "ETH Amount" : "Token Amount"}</span>
                    <span className="label-text-alt">
                      {activeTab === "buy"
                        ? `Balance: ${ethBalance ? formatEther(ethBalance.value).slice(0, 8) : "0"} ETH`
                        : `Balance: ${userBalance ? Number(userBalance / BigInt(1e18)).toLocaleString() : "0"}`}
                    </span>
                  </label>
                  <input
                    type="number"
                    placeholder="0.0"
                    className="input input-bordered w-full font-mono"
                    value={amount}
                    onChange={e => setAmount(e.target.value)}
                    disabled={isTransacting}
                    step="0.001"
                    min="0"
                  />
                </div>

                <div className="flex gap-2 mt-2">
                  {activeTab === "buy" ? (
                    <>
                      <button className="btn btn-xs btn-outline" onClick={() => setAmount("0.0001")}>
                        0.0001
                      </button>
                      <button className="btn btn-xs btn-outline" onClick={() => setAmount("0.0005")}>
                        0.0005
                      </button>
                      <button className="btn btn-xs btn-outline" onClick={() => setAmount("0.001")}>
                        0.001
                      </button>
                    </>
                  ) : (
                    <>
                      <button
                        className="btn btn-xs btn-outline"
                        onClick={() => userBalance && setAmount(formatEther(userBalance / 4n))}
                      >
                        25%
                      </button>
                      <button
                        className="btn btn-xs btn-outline"
                        onClick={() => userBalance && setAmount(formatEther(userBalance / 2n))}
                      >
                        50%
                      </button>
                      <button
                        className="btn btn-xs btn-outline"
                        onClick={() => userBalance && setAmount(formatEther(userBalance))}
                      >
                        Max
                      </button>
                    </>
                  )}
                </div>

                <div className="bg-base-200 rounded-lg p-3 mt-4">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="text-sm text-base-content/60">You will receive (approx)</div>
                      <div className="font-mono font-semibold text-lg">
                        {activeTab === "buy"
                          ? `${estimatedTokens !== undefined ? (Number(estimatedTokens) / 1e18).toFixed(4) : "0"} ${symbol || "tokens"}`
                          : `${
                              estimatedEth !== undefined
                                ? Number(formatEther(estimatedEth))
                                    .toFixed(10)
                                    .replace(/\.?0+$/, "")
                                : "0"
                            } ETH`}
                      </div>
                    </div>
                    <div className="text-right">
                      <div className="text-xs text-base-content/60">Slippage</div>
                      <div className="font-mono text-sm">{slippagePercent}%</div>
                    </div>
                  </div>
                  <div className="mt-3 flex items-start justify-between gap-3 border-t border-base-300 pt-3">
                    <div className="text-sm text-base-content/60">Minimum received</div>
                    <div className="text-right font-mono text-sm">
                      {minimumReceived !== null
                        ? activeTab === "buy"
                          ? `${minimumReceived.toFixed(4)} ${symbol || "tokens"}`
                          : `${minimumReceived.toFixed(10).replace(/\.?0+$/, "")} ETH`
                        : "-"}
                    </div>
                  </div>
                  <div className="text-xs text-base-content/60 mt-2">
                    {activeTab === "buy" ? `${buyFeePercent}% fee applied` : `${sellFeePercent}% fee applied`}
                  </div>
                </div>

                <button
                  className={`btn btn-lg w-full mt-4 ${activeTab === "buy" ? "btn-primary" : "btn-secondary"}`}
                  onClick={activeTab === "buy" ? handleBuy : handleSell}
                  disabled={isTransacting || !amount || parseFloat(amount) <= 0}
                >
                  {isTransacting ? (
                    <>
                      <span className="loading loading-spinner"></span>
                      Processing...
                    </>
                  ) : activeTab === "buy" ? (
                    "Buy Tokens"
                  ) : (
                    "Sell Tokens"
                  )}
                </button>
              </>
            )}
          </div>
        </div>

        <RecentTradesPanel trades={recentTrades} tokenSymbol={symbol || "TOKEN"} isLive={isMarketLive} />
      </div>

      {showSlippageSettings && (
        <div className="modal modal-open">
          <div className="modal-box">
            <h3 className="text-lg font-semibold">Slippage Settings</h3>

            <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
              {SLIPPAGE_OPTIONS.map(option => (
                <button
                  key={option}
                  className={`btn ${slippagePercent === option ? "btn-primary" : "btn-outline"}`}
                  onClick={() => setSlippagePercent(option)}
                >
                  {option}%
                </button>
              ))}
            </div>

            <div className="modal-action">
              <button className="btn" onClick={() => setShowSlippageSettings(false)}>
                Close
              </button>
            </div>
          </div>
        </div>
      )}

      <div className="mt-6 text-center text-sm text-base-content/60">
        Token Contract:{" "}
        <Address
          address={tokenAddress}
          chain={targetNetwork}
          blockExplorerAddressLink={
            targetNetwork.id === hardhat.id ? `/blockexplorer/address/${tokenAddress}` : undefined
          }
        />
      </div>

      {/* Security Test - Only visible to creator, only before graduation */}
      {isCreator && !graduated && (
        <div className="mt-6">
          <div className="card bg-info/10 border-2 border-info shadow-xl">
            <div className="card-body">
              <h3 className="card-title text-info gap-2">
                <BeakerIcon className="w-6 h-6" />
                Security Test: V2 Pair Transfer Blocking
              </h3>
              <p className="text-sm text-base-content/70">
                Test that tokens cannot be transferred to the V2 pool address before graduation. This prevents
                front-running attacks on pool creation.
              </p>

              {/* Show expected V2 pair address */}
              <div className="bg-base-200 rounded-lg p-3 mt-2">
                <div className="text-xs text-base-content/60">Expected V2 Pair Address</div>
                <div className="font-mono text-sm break-all">{expectedV2Pair || "Loading..."}</div>
                <div className="text-xs text-base-content/50 mt-1">
                  Transfers to this address are blocked until graduation
                </div>
              </div>

              <button
                className="btn btn-info btn-lg w-full mt-4 gap-2"
                onClick={handleTestAddLiquidity}
                disabled={isTestingLiquidity || !userBalance || userBalance === 0n}
              >
                {isTestingLiquidity ? (
                  <>
                    <span className="loading loading-spinner"></span>
                    Testing...
                  </>
                ) : (
                  <>
                    <BeakerIcon className="w-5 h-5" />
                    Try Add Liquidity (Should Fail)
                  </>
                )}
              </button>
              <p className="text-xs text-center text-base-content/60 mt-2">
                This will attempt to add liquidity directly to V2. It should fail with "TransferToPoolBlocked" error.
              </p>
            </div>
          </div>
        </div>
      )}

      {/* Rug Button - Only visible to creator */}
      {isCreator && (
        <div className="mt-6">
          <div className="card bg-error/10 border-2 border-error shadow-xl">
            <div className="card-body">
              <h3 className="card-title text-error gap-2">
                <ExclamationTriangleIcon className="w-6 h-6" />
                Emergency Withdraw (Testing Only)
              </h3>
              <p className="text-sm text-base-content/70">
                As the token creator, you can drain all funds from this token. This feature is for testing only.
              </p>

              {/* Show what will be drained */}
              <div className="bg-base-200 rounded-lg p-3 mt-2">
                <div className="text-sm font-semibold mb-2">Funds to withdraw:</div>
                {!graduated && (
                  <div className="grid grid-cols-2 gap-2 text-sm">
                    <div>
                      <span className="text-base-content/60">Reserve Balance:</span>
                    </div>
                    <div className="font-mono">{reserveBalance ? formatEther(reserveBalance) : "0"} ETH</div>
                    <div>
                      <span className="text-base-content/60">Treasury:</span>
                    </div>
                    <div className="font-mono">{treasury ? formatEther(treasury) : "0"} ETH</div>
                    <div className="col-span-2 border-t border-base-300 pt-1 mt-1">
                      <span className="font-semibold">Total: </span>
                      <span className="font-mono">{formatEther((reserveBalance || 0n) + (treasury || 0n))} ETH</span>
                    </div>
                  </div>
                )}
                {graduated && graduationFunds && graduationFunds > 0n && (
                  <div className="text-sm">
                    <span className="text-base-content/60">Graduation Funds: </span>
                    <span className="font-mono">{formatEther(graduationFunds)} ETH</span>
                  </div>
                )}
                {graduated && hasPool && poolReserves && (
                  <div className="grid grid-cols-2 gap-2 text-sm">
                    <div>
                      <span className="text-base-content/60">Pool ETH Reserve:</span>
                    </div>
                    <div className="font-mono">{formatEther(poolReserves[0])} ETH</div>
                    <div>
                      <span className="text-base-content/60">Pool Token Reserve:</span>
                    </div>
                    <div className="font-mono">
                      {(Number(poolReserves[1]) / 1e18).toFixed(4)} {symbol}
                    </div>
                  </div>
                )}
                {graduated && !hasPool && (!graduationFunds || graduationFunds === 0n) && (
                  <div className="text-sm text-base-content/60">No funds available to withdraw</div>
                )}
              </div>

              <button
                className="btn btn-error btn-lg w-full mt-4 gap-2"
                onClick={() => setShowRugModal(true)}
                disabled={
                  (!graduated && (!reserveBalance || reserveBalance === 0n) && (!treasury || treasury === 0n)) ||
                  (graduated && (!graduationFunds || graduationFunds === 0n) && !hasPool)
                }
              >
                <ExclamationTriangleIcon className="w-5 h-5" />
                RUG (Testing Only)
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Rug Confirmation Modal */}
      {showRugModal && (
        <div className="modal modal-open">
          <div className="modal-box border-2 border-error">
            <h3 className="font-bold text-lg text-error flex items-center gap-2">
              <ExclamationTriangleIcon className="w-6 h-6" />
              Confirm Emergency Withdraw
            </h3>
            <p className="py-4">Are you sure you want to drain all funds? This action cannot be undone.</p>
            <div className="bg-error/10 rounded-lg p-3 mb-4">
              <div className="text-sm">
                {!graduated && (
                  <>
                    <p>
                      <strong>Action:</strong> Drain bonding curve
                    </p>
                    <p>
                      <strong>Amount:</strong> {formatEther((reserveBalance || 0n) + (treasury || 0n))} ETH
                    </p>
                  </>
                )}
                {graduated && graduationFunds && graduationFunds > 0n && (
                  <>
                    <p>
                      <strong>Action:</strong> Drain graduation funds
                    </p>
                    <p>
                      <strong>Amount:</strong> {formatEther(graduationFunds)} ETH
                    </p>
                  </>
                )}
                {graduated && hasPool && poolReserves && (
                  <>
                    <p>
                      <strong>Action:</strong> Drain pool
                    </p>
                    <p>
                      <strong>ETH:</strong> {formatEther(poolReserves[0])} ETH
                    </p>
                    <p>
                      <strong>Tokens:</strong> {(Number(poolReserves[1]) / 1e18).toFixed(4)} {symbol}
                    </p>
                  </>
                )}
              </div>
            </div>
            <div className="modal-action">
              <button className="btn btn-ghost" onClick={() => setShowRugModal(false)} disabled={isRugging}>
                Cancel
              </button>
              <button className="btn btn-error" onClick={handleRug} disabled={isRugging}>
                {isRugging ? (
                  <>
                    <span className="loading loading-spinner"></span>
                    Rugging...
                  </>
                ) : (
                  "Confirm Rug"
                )}
              </button>
            </div>
          </div>
          <div className="modal-backdrop bg-black/50" onClick={() => !isRugging && setShowRugModal(false)}></div>
        </div>
      )}
    </div>
  );
};

export default TokenPage;
