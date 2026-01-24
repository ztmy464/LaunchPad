"use client";

import { useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { formatEther, maxUint256, parseEther } from "viem";
import { hardhat } from "viem/chains";
import { useAccount, useBalance, useReadContract, useWriteContract } from "wagmi";
import {
  ArrowLeftIcon,
  ArrowsRightLeftIcon,
  ArrowTopRightOnSquareIcon,
  BanknotesIcon,
  BeakerIcon,
  ClockIcon,
  ExclamationTriangleIcon,
  MinusIcon,
  PlusIcon,
  RocketLaunchIcon,
} from "@heroicons/react/24/outline";
import { ERC20ApproveABI, LaunchTokenABI, SimplePoolABI, TokenFactoryABI } from "~~/contracts/externalContracts";
import { useDeployedContractInfo, useTargetNetwork } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

// Pool Swap Interface Component for Graduated Tokens
const PoolSwapInterface = ({
  tokenAddress,
  symbol,
  userBalance,
  refetchAllData,
  buyFeePercent,
  sellFeePercent,
}: {
  tokenAddress: `0x${string}`;
  symbol: string;
  userBalance: bigint | undefined;
  refetchAllData: () => void;
  buyFeePercent: number;
  sellFeePercent: number;
}) => {
  const { address: userAddress, isConnected } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const [mainTab, setMainTab] = useState<"swap" | "liquidity">("swap");
  const [swapTab, setSwapTab] = useState<"buy" | "sell">("buy");
  const [liquidityTab, setLiquidityTab] = useState<"add" | "remove">("add");
  const [swapAmount, setSwapAmount] = useState("0.0001");
  const [liquidityAmount, setLiquidityAmount] = useState("");
  const [isSwapping, setIsSwapping] = useState(false);
  const [isLiquidityAction, setIsLiquidityAction] = useState(false);

  // Get SimplePool address
  const { data: simplePoolInfo } = useDeployedContractInfo({ contractName: "SimplePool" });
  const simplePoolAddress = simplePoolInfo?.address;

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

  // Check if pool exists
  const { data: hasPool, refetch: refetchHasPool } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "hasPool",
    args: [tokenAddress],
    query: { enabled: !!simplePoolAddress, refetchInterval: 3000 },
  });

  // Get pool reserves
  const { data: reserves, refetch: refetchReserves } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "getReserves",
    args: [tokenAddress],
    query: { enabled: !!simplePoolAddress && !!hasPool, refetchInterval: 3000 },
  });

  // Get user's LP balance
  const { data: userLpBalance, refetch: refetchUserLpBalance } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "getLiquidity",
    args: [tokenAddress, userAddress || "0x0"],
    query: { enabled: !!simplePoolAddress && !!hasPool && !!userAddress, refetchInterval: 3000 },
  });

  // Get total LP supply
  const { data: totalLpSupply, refetch: refetchTotalLpSupply } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "getTotalLiquidity",
    args: [tokenAddress],
    query: { enabled: !!simplePoolAddress && !!hasPool, refetchInterval: 3000 },
  });

  // Estimate buy output
  const buyAmountWei = swapTab === "buy" && swapAmount ? parseEther(swapAmount) : 0n;
  const { data: estimatedBuyTokens } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "estimateBuyOutput",
    args: [tokenAddress, buyAmountWei],
    query: { enabled: !!simplePoolAddress && !!hasPool && buyAmountWei > 0n },
  });

  // Estimate sell output
  const sellAmountWei = swapTab === "sell" && swapAmount ? parseEther(swapAmount) : 0n;
  const { data: estimatedSellEth } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "estimateSellOutput",
    args: [tokenAddress, sellAmountWei],
    query: { enabled: !!simplePoolAddress && !!hasPool && sellAmountWei > 0n },
  });

  // Estimate add liquidity
  const addLiquidityAmountWei = liquidityTab === "add" && liquidityAmount ? parseEther(liquidityAmount) : 0n;
  const { data: estimatedAddLiquidity } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "estimateAddLiquidity",
    args: [tokenAddress, addLiquidityAmountWei],
    query: { enabled: !!simplePoolAddress && !!hasPool && addLiquidityAmountWei > 0n },
  });

  // Estimate remove liquidity
  const removeLiquidityAmountWei = liquidityTab === "remove" && liquidityAmount ? parseEther(liquidityAmount) : 0n;
  const { data: estimatedRemoveLiquidity } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "estimateRemoveLiquidity",
    args: [tokenAddress, removeLiquidityAmountWei],
    query: { enabled: !!simplePoolAddress && !!hasPool && removeLiquidityAmountWei > 0n },
  });

  // Check token allowance for SimplePool
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: tokenAddress,
    abi: ERC20ApproveABI,
    functionName: "allowance",
    args: [userAddress || "0x0", simplePoolAddress || "0x0"],
    query: { enabled: !!userAddress && !!simplePoolAddress },
  });

  const { writeContractAsync } = useWriteContract();

  // Helper to refetch all liquidity-related data
  const refetchLiquidityData = () => {
    refetchReserves();
    refetchUserLpBalance();
    refetchTotalLpSupply();
    refetchEthBalance();
    refetchAllData();
  };

  // Create Pool using factory's graduation funds (ensures price continuity)
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
      notification.info("Creating pool with graduation funds...");
      await writeContractAsync({
        address: tokenFactoryAddress,
        abi: TokenFactoryABI,
        functionName: "createGraduatedPool",
        args: [tokenAddress],
      });

      notification.success("Pool created successfully with price continuity!");
      refetchHasPool();
      refetchReserves();
      refetchGraduationFunds();
      refetchAllData();
    } catch (error: any) {
      notification.error(error.message || "Failed to create pool");
    } finally {
      setIsSwapping(false);
    }
  };

  // Buy tokens
  const handleBuy = async () => {
    if (!simplePoolAddress || !swapAmount) {
      notification.error("Please enter an amount");
      return;
    }

    setIsSwapping(true);
    try {
      const ethAmount = parseEther(swapAmount);

      await writeContractAsync({
        address: simplePoolAddress,
        abi: SimplePoolABI,
        functionName: "buyTokens",
        args: [tokenAddress, 0n], // 0 minOut for testing
        value: ethAmount,
      });

      notification.success("Buy successful!");
      setSwapAmount("");
      refetchLiquidityData();
    } catch (error: any) {
      notification.error(error.message || "Buy failed");
    } finally {
      setIsSwapping(false);
    }
  };

  // Sell tokens
  const handleSell = async () => {
    if (!simplePoolAddress || !swapAmount) {
      notification.error("Please enter an amount");
      return;
    }

    setIsSwapping(true);
    try {
      const tokenAmount = parseEther(swapAmount);

      // Approve if needed
      if ((allowance || 0n) < tokenAmount) {
        notification.info("Approving tokens...");
        await writeContractAsync({
          address: tokenAddress,
          abi: ERC20ApproveABI,
          functionName: "approve",
          args: [simplePoolAddress, maxUint256],
        });
        await refetchAllowance();
      }

      await writeContractAsync({
        address: simplePoolAddress,
        abi: SimplePoolABI,
        functionName: "sellTokens",
        args: [tokenAddress, tokenAmount, 0n], // 0 minOut for testing
      });

      notification.success("Sell successful!");
      setSwapAmount("");
      refetchLiquidityData();
    } catch (error: any) {
      notification.error(error.message || "Sell failed");
    } finally {
      setIsSwapping(false);
    }
  };

  // Add liquidity
  const handleAddLiquidity = async () => {
    if (!simplePoolAddress || !liquidityAmount) {
      notification.error("Please enter an amount");
      return;
    }

    const ethAmount = parseEther(liquidityAmount);
    const tokensRequired = estimatedAddLiquidity?.[0] || 0n;

    if (tokensRequired === 0n) {
      notification.error("Could not calculate required tokens");
      return;
    }

    // Check if user has enough tokens
    if ((userBalance || 0n) < tokensRequired) {
      notification.error(`Insufficient token balance. Need ${(Number(tokensRequired) / 1e18).toFixed(4)} ${symbol}`);
      return;
    }

    setIsLiquidityAction(true);
    try {
      // Approve tokens if needed
      if ((allowance || 0n) < tokensRequired) {
        notification.info("Approving tokens...");
        await writeContractAsync({
          address: tokenAddress,
          abi: ERC20ApproveABI,
          functionName: "approve",
          args: [simplePoolAddress, maxUint256],
        });
        await refetchAllowance();
      }

      await writeContractAsync({
        address: simplePoolAddress,
        abi: SimplePoolABI,
        functionName: "addLiquidity",
        args: [tokenAddress, 0n], // 0 minLP for testing
        value: ethAmount,
      });

      notification.success("Liquidity added successfully!");
      setLiquidityAmount("");
      refetchLiquidityData();
    } catch (error: any) {
      notification.error(error.message || "Failed to add liquidity");
    } finally {
      setIsLiquidityAction(false);
    }
  };

  // Remove liquidity
  const handleRemoveLiquidity = async () => {
    if (!simplePoolAddress || !liquidityAmount) {
      notification.error("Please enter an amount");
      return;
    }

    const lpAmount = parseEther(liquidityAmount);

    if ((userLpBalance || 0n) < lpAmount) {
      notification.error("Insufficient LP balance");
      return;
    }

    setIsLiquidityAction(true);
    try {
      await writeContractAsync({
        address: simplePoolAddress,
        abi: SimplePoolABI,
        functionName: "removeLiquidity",
        args: [tokenAddress, lpAmount, 0n, 0n], // 0 minimums for testing
      });

      notification.success("Liquidity removed successfully!");
      setLiquidityAmount("");
      refetchLiquidityData();
    } catch (error: any) {
      notification.error(error.message || "Failed to remove liquidity");
    } finally {
      setIsLiquidityAction(false);
    }
  };

  // If SimplePool not deployed
  if (!simplePoolAddress) {
    return (
      <div className="space-y-4">
        <div className="alert alert-success">
          <RocketLaunchIcon className="w-5 h-5" />
          <div>
            <div className="font-semibold">Graduated!</div>
            <div className="text-sm">Pool contracts not deployed yet.</div>
          </div>
        </div>
      </div>
    );
  }

  // If pool doesn't exist yet
  if (!hasPool) {
    return (
      <div className="space-y-4">
        <div className="alert alert-success">
          <RocketLaunchIcon className="w-5 h-5" />
          <div>
            <div className="font-semibold">Graduated!</div>
            <div className="text-sm">Create a liquidity pool to enable trading.</div>
          </div>
        </div>

        {/* Show graduation funds info */}
        {graduationFunds && graduationFunds > 0n && (
          <div className="bg-base-200 rounded-lg p-3">
            <div className="text-xs text-base-content/60 mb-1">Graduation Funds Available</div>
            <div className="font-mono font-semibold text-primary">{formatEther(graduationFunds)} ETH</div>
            <div className="text-xs text-base-content/50 mt-1">
              Will be paired with tokens at the final bonding curve price
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
                  Creating Pool...
                </>
              ) : (
                <>
                  <PlusIcon className="w-5 h-5" />
                  Create Pool
                </>
              )}
            </button>
            <p className="text-xs text-center text-base-content/60">
              Creates pool with graduation funds at the final bonding curve price for seamless trading
            </p>
          </>
        ) : (
          <div className="alert alert-warning">Connect wallet to create pool</div>
        )}
      </div>
    );
  }

  // Pool exists - show swap/liquidity interface
  const [ethReserve, tokenReserve] = reserves || [0n, 0n];
  const poolSharePercent =
    totalLpSupply && totalLpSupply > 0n && userLpBalance ? Number((userLpBalance * 10000n) / totalLpSupply) / 100 : 0;

  // Calculate user's share of pool in ETH and tokens
  const userEthShare =
    totalLpSupply && totalLpSupply > 0n && userLpBalance ? (userLpBalance * ethReserve) / totalLpSupply : 0n;
  const userTokenShare =
    totalLpSupply && totalLpSupply > 0n && userLpBalance ? (userLpBalance * tokenReserve) / totalLpSupply : 0n;

  // Build Uniswap URL based on chain
  const getUniswapUrl = () => {
    // Map chain IDs to Uniswap chain names
    const chainNames: Record<number, string> = {
      1: "ethereum",
      8453: "base",
      10: "optimism",
      42161: "arbitrum",
      137: "polygon",
    };
    const chainName = chainNames[targetNetwork.id];
    if (!chainName) return null;
    return `https://app.uniswap.org/explore/tokens/${chainName}/${tokenAddress}`;
  };
  
  const uniswapUrl = getUniswapUrl();

  return (
    <div className="space-y-4">
      <div className="alert alert-success">
        <RocketLaunchIcon className="w-5 h-5" />
        <div className="flex-1">
          <div className="font-semibold">Trading on Pool!</div>
          <div className="text-sm">
            {buyFeePercent}% buy fee / {sellFeePercent}% sell fee
          </div>
        </div>
        {uniswapUrl && (
          <a
            href={uniswapUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="btn btn-sm btn-ghost gap-1"
          >
            <ArrowTopRightOnSquareIcon className="w-4 h-4" />
            Uniswap
          </a>
        )}
      </div>

      {/* Pool Stats */}
      <div className="bg-base-200 rounded-lg p-3">
        <div className="text-xs text-base-content/60 mb-1">Pool Reserves</div>
        <div className="grid grid-cols-2 gap-2 text-sm font-mono">
          <div>{formatEther(ethReserve).slice(0, 8)} ETH</div>
          <div>
            {Number(tokenReserve / BigInt(1e18)).toLocaleString()} {symbol}
          </div>
        </div>
      </div>

      {!isConnected ? (
        <div className="alert alert-warning">Connect wallet to trade</div>
      ) : (
        <>
          {/* Main Tab Buttons: Swap / Liquidity */}
          <div className="tabs tabs-boxed">
            <button
              className={`tab flex-1 ${mainTab === "swap" ? "tab-active" : ""}`}
              onClick={() => {
                setMainTab("swap");
                setSwapAmount("");
              }}
            >
              <ArrowsRightLeftIcon className="w-4 h-4 mr-1" />
              Swap
            </button>
            <button
              className={`tab flex-1 ${mainTab === "liquidity" ? "tab-active" : ""}`}
              onClick={() => {
                setMainTab("liquidity");
                setLiquidityAmount("");
              }}
            >
              <BeakerIcon className="w-4 h-4 mr-1" />
              Liquidity
            </button>
          </div>

          {mainTab === "swap" ? (
            <>
              {/* Swap Sub-tabs: Buy / Sell */}
              <div className="tabs tabs-boxed tabs-sm">
                <button
                  className={`tab flex-1 ${swapTab === "buy" ? "tab-active" : ""}`}
                  onClick={() => {
                    setSwapTab("buy");
                    setSwapAmount("");
                  }}
                >
                  Buy
                </button>
                <button
                  className={`tab flex-1 ${swapTab === "sell" ? "tab-active" : ""}`}
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
                    <button className="btn btn-xs btn-outline" onClick={() => setSwapAmount("0.0005")}>
                      0.0005
                    </button>
                    <button className="btn btn-xs btn-outline" onClick={() => setSwapAmount("0.001")}>
                      0.001
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
                    : `${estimatedSellEth !== undefined ? Number(formatEther(estimatedSellEth)).toFixed(10).replace(/\.?0+$/, "") : "0"} ETH`}
                </div>
                <div className="text-xs text-base-content/60 mt-1">
                  {swapTab === "buy" ? `${buyFeePercent}% fee applied` : `${sellFeePercent}% fee applied`}
                </div>
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
          ) : (
            <>
              {/* LP Position Display */}
              {userLpBalance && userLpBalance > 0n && (
                <div className="bg-gradient-to-r from-primary/10 to-secondary/10 rounded-lg p-3 border border-primary/20">
                  <div className="text-xs text-base-content/60 mb-2">Your LP Position</div>
                  <div className="grid grid-cols-2 gap-2 text-sm">
                    <div>
                      <div className="text-xs text-base-content/50">LP Tokens</div>
                      <div className="font-mono font-semibold">{(Number(userLpBalance) / 1e18).toFixed(4)}</div>
                    </div>
                    <div>
                      <div className="text-xs text-base-content/50">Pool Share</div>
                      <div className="font-mono font-semibold text-primary">{poolSharePercent.toFixed(2)}%</div>
                    </div>
                    <div>
                      <div className="text-xs text-base-content/50">ETH Value</div>
                      <div className="font-mono">{formatEther(userEthShare).slice(0, 8)} ETH</div>
                    </div>
                    <div>
                      <div className="text-xs text-base-content/50">{symbol} Value</div>
                      <div className="font-mono">{(Number(userTokenShare) / 1e18).toFixed(2)}</div>
                    </div>
                  </div>
                </div>
              )}

              {/* Liquidity Sub-tabs: Add / Remove */}
              <div className="tabs tabs-boxed tabs-sm">
                <button
                  className={`tab flex-1 gap-1 ${liquidityTab === "add" ? "tab-active" : ""}`}
                  onClick={() => {
                    setLiquidityTab("add");
                    setLiquidityAmount("");
                  }}
                >
                  <PlusIcon className="w-3 h-3" />
                  Add
                </button>
                <button
                  className={`tab flex-1 gap-1 ${liquidityTab === "remove" ? "tab-active" : ""}`}
                  onClick={() => {
                    setLiquidityTab("remove");
                    setLiquidityAmount("");
                  }}
                >
                  <MinusIcon className="w-3 h-3" />
                  Remove
                </button>
              </div>

              {liquidityTab === "add" ? (
                <>
                  {/* Add Liquidity */}
                  <div className="form-control">
                    <label className="label">
                      <span className="label-text">ETH Amount</span>
                      <span className="label-text-alt">
                        Balance: {ethBalance ? formatEther(ethBalance.value).slice(0, 8) : "0"} ETH
                      </span>
                    </label>
                    <input
                      type="number"
                      placeholder="0.0"
                      className="input input-bordered w-full font-mono"
                      value={liquidityAmount}
                      onChange={e => setLiquidityAmount(e.target.value)}
                      disabled={isLiquidityAction}
                      step="0.001"
                      min="0"
                    />
                  </div>

                  <div className="flex gap-2">
                    <button className="btn btn-xs btn-outline" onClick={() => setLiquidityAmount("0.0001")}>
                      0.0001
                    </button>
                    <button className="btn btn-xs btn-outline" onClick={() => setLiquidityAmount("0.0005")}>
                      0.0005
                    </button>
                    <button className="btn btn-xs btn-outline" onClick={() => setLiquidityAmount("0.05")}>
                      0.05
                    </button>
                  </div>

                  {/* Estimate for Add */}
                  <div className="bg-base-200 rounded-lg p-3">
                    <div className="text-sm text-base-content/60 mb-2">You will deposit</div>
                    <div className="grid grid-cols-2 gap-2 text-sm">
                      <div>
                        <div className="text-xs text-base-content/50">ETH</div>
                        <div className="font-mono font-semibold">{liquidityAmount || "0"}</div>
                      </div>
                      <div>
                        <div className="text-xs text-base-content/50">{symbol} Required</div>
                        <div className="font-mono font-semibold">
                          {estimatedAddLiquidity?.[0] !== undefined
                            ? (Number(estimatedAddLiquidity[0]) / 1e18).toFixed(4)
                            : "0"}
                        </div>
                      </div>
                    </div>
                    <div className="divider my-2"></div>
                    <div className="text-sm text-base-content/60">You will receive</div>
                    <div className="font-mono font-semibold text-primary">
                      {estimatedAddLiquidity?.[1] !== undefined
                        ? (Number(estimatedAddLiquidity[1]) / 1e18).toFixed(4)
                        : "0"}{" "}
                      LP Tokens
                    </div>
                  </div>

                  <button
                    className="btn btn-lg w-full btn-primary"
                    onClick={handleAddLiquidity}
                    disabled={isLiquidityAction || !liquidityAmount || parseFloat(liquidityAmount) <= 0}
                  >
                    {isLiquidityAction ? (
                      <>
                        <span className="loading loading-spinner"></span>
                        Adding Liquidity...
                      </>
                    ) : (
                      <>
                        <PlusIcon className="w-5 h-5" />
                        Add Liquidity
                      </>
                    )}
                  </button>
                </>
              ) : (
                <>
                  {/* Remove Liquidity */}
                  <div className="form-control">
                    <label className="label">
                      <span className="label-text">LP Tokens to Remove</span>
                      <span className="label-text-alt">
                        Balance: {userLpBalance ? (Number(userLpBalance) / 1e18).toFixed(4) : "0"}
                      </span>
                    </label>
                    <input
                      type="number"
                      placeholder="0.0"
                      className="input input-bordered w-full font-mono"
                      value={liquidityAmount}
                      onChange={e => setLiquidityAmount(e.target.value)}
                      disabled={isLiquidityAction}
                      step="0.0001"
                      min="0"
                    />
                  </div>

                  <div className="flex gap-2">
                    <button
                      className="btn btn-xs btn-outline"
                      onClick={() => userLpBalance && setLiquidityAmount(formatEther(userLpBalance / 4n))}
                    >
                      25%
                    </button>
                    <button
                      className="btn btn-xs btn-outline"
                      onClick={() => userLpBalance && setLiquidityAmount(formatEther(userLpBalance / 2n))}
                    >
                      50%
                    </button>
                    <button
                      className="btn btn-xs btn-outline"
                      onClick={() => userLpBalance && setLiquidityAmount(formatEther(userLpBalance))}
                    >
                      Max
                    </button>
                  </div>

                  {/* Estimate for Remove */}
                  <div className="bg-base-200 rounded-lg p-3">
                    <div className="text-sm text-base-content/60 mb-2">You will receive</div>
                    <div className="grid grid-cols-2 gap-2 text-sm">
                      <div>
                        <div className="text-xs text-base-content/50">ETH</div>
                        <div className="font-mono font-semibold">
                          {estimatedRemoveLiquidity?.[0] !== undefined
                            ? Number(formatEther(estimatedRemoveLiquidity[0])).toFixed(6)
                            : "0"}
                        </div>
                      </div>
                      <div>
                        <div className="text-xs text-base-content/50">{symbol}</div>
                        <div className="font-mono font-semibold">
                          {estimatedRemoveLiquidity?.[1] !== undefined
                            ? (Number(estimatedRemoveLiquidity[1]) / 1e18).toFixed(4)
                            : "0"}
                        </div>
                      </div>
                    </div>
                  </div>

                  <button
                    className="btn btn-lg w-full btn-secondary"
                    onClick={handleRemoveLiquidity}
                    disabled={
                      isLiquidityAction ||
                      !liquidityAmount ||
                      parseFloat(liquidityAmount) <= 0 ||
                      !userLpBalance ||
                      userLpBalance === 0n
                    }
                  >
                    {isLiquidityAction ? (
                      <>
                        <span className="loading loading-spinner"></span>
                        Removing Liquidity...
                      </>
                    ) : (
                      <>
                        <MinusIcon className="w-5 h-5" />
                        Remove Liquidity
                      </>
                    )}
                  </button>
                </>
              )}

              <p className="text-xs text-center text-base-content/60">
                Add liquidity to earn fees from every swap. Your share grows as fees accumulate.
              </p>
            </>
          )}
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
  const [showRugModal, setShowRugModal] = useState(false);
  const [isRugging, setIsRugging] = useState(false);

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

  // Read config values from TokenFactory (uses deployed contract info)
  const { data: tokenFactoryInfo } = useDeployedContractInfo({ contractName: "TokenFactory" });
  const tokenFactoryAddress = tokenFactoryInfo?.address;

  // Read SimplePool info
  const { data: simplePoolInfo } = useDeployedContractInfo({ contractName: "SimplePool" });
  const simplePoolAddress = simplePoolInfo?.address;

  // Read graduation funds from factory (for post-graduation rug)
  const { data: graduationFunds, refetch: refetchGraduationFunds } = useReadContract({
    address: tokenFactoryAddress,
    abi: TokenFactoryABI,
    functionName: "graduationFunds",
    args: [tokenAddress],
    query: { enabled: !!tokenFactoryAddress, refetchInterval: 3000 },
  });

  // Check if pool exists
  const { data: hasPool, refetch: refetchHasPool } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "hasPool",
    args: [tokenAddress],
    query: { enabled: !!simplePoolAddress, refetchInterval: 3000 },
  });

  // Get pool reserves (for pool rug)
  const { data: poolReserves, refetch: refetchPoolReserves } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "getReserves",
    args: [tokenAddress],
    query: { enabled: !!simplePoolAddress && !!hasPool, refetchInterval: 3000 },
  });

  // Get pool creator (to verify rug permissions)
  const { data: poolCreator } = useReadContract({
    address: simplePoolAddress,
    abi: SimplePoolABI,
    functionName: "tokenCreators",
    args: [tokenAddress],
    query: { enabled: !!simplePoolAddress && !!hasPool },
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
      setTimeout(refetchAllData, 500);
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
      setTimeout(refetchAllData, 500);
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
        // Pool active: drain the pool
        if (!simplePoolAddress) {
          notification.error("SimplePool address not found");
          return;
        }
        await writeContractAsync({
          address: simplePoolAddress,
          abi: SimplePoolABI,
          functionName: "emergencyDrainPool",
          args: [tokenAddress],
        });
        notification.success("Pool drained!");
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

  return (
    <div className="container mx-auto px-6 py-8 max-w-4xl">
      <Link href="/" className="btn btn-ghost btn-sm gap-2 mb-6">
        <ArrowLeftIcon className="w-4 h-4" />
        Back to Tokens
      </Link>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Token Info Card */}
        <div className="lg:col-span-2 space-y-6">
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

              {/* Reserve & Earnings - show both values */}
              <div className="grid grid-cols-2 gap-4 mt-4">
                <div className="bg-base-200 rounded-lg p-3">
                  <div className="text-xs text-base-content/60">Bonding Curve Reserve</div>
                  <div className="font-mono font-semibold text-primary">
                    {reserveBalance ? formatEther(reserveBalance) : "0"} ETH
                  </div>
                  <div className="text-xs text-base-content/50 mt-1">Used for V4 liquidity at graduation</div>
                </div>
                <div className="bg-base-200 rounded-lg p-3">
                  <div className="text-xs text-base-content/60">Creator Earnings</div>
                  <div className="font-mono font-semibold text-success">
                    {treasury ? formatEther(treasury) : "0"} ETH
                  </div>
                  <div className="text-xs text-base-content/50 mt-1">
                    From {buyFeePercent}% buy / {sellFeePercent}% sell fees
                  </div>
                  {isCreator && treasury && treasury > 0n && (
                    <button
                      className="btn btn-success btn-xs mt-2 gap-1"
                      onClick={handleWithdrawTreasury}
                      disabled={isWithdrawing}
                    >
                      {isWithdrawing ? (
                        <span className="loading loading-spinner loading-xs"></span>
                      ) : (
                        <BanknotesIcon className="w-3 h-3" />
                      )}
                      Withdraw
                    </button>
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

        {/* Trade Card */}
        <div className="card bg-base-100 shadow-xl">
          <div className="card-body">
            <h2 className="card-title">
              <ArrowsRightLeftIcon className="w-5 h-5" />
              Trade
            </h2>

            {graduated ? (
              <PoolSwapInterface
                tokenAddress={tokenAddress}
                symbol={symbol || "TOKEN"}
                userBalance={userBalance}
                refetchAllData={refetchAllData}
                buyFeePercent={buyFeePercent}
                sellFeePercent={sellFeePercent}
              />
            ) : !isConnected ? (
              <div className="alert alert-warning">
                <span>Connect wallet to trade</span>
              </div>
            ) : (
              <>
                <div className="tabs tabs-boxed mb-4">
                  <button
                    className={`tab flex-1 ${activeTab === "buy" ? "tab-active" : ""}`}
                    onClick={() => {
                      setActiveTab("buy");
                      setAmount("");
                    }}
                  >
                    Buy
                  </button>
                  <button
                    className={`tab flex-1 ${activeTab === "sell" ? "tab-active" : ""}`}
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
                  <div className="text-sm text-base-content/60">You will receive (approx)</div>
                  <div className="font-mono font-semibold text-lg">
                    {activeTab === "buy"
                      ? `${estimatedTokens !== undefined ? (Number(estimatedTokens) / 1e18).toFixed(4) : "0"} ${symbol || "tokens"}`
                      : `${estimatedEth !== undefined ? Number(formatEther(estimatedEth)).toFixed(10).replace(/\.?0+$/, "") : "0"} ETH`}
                  </div>
                  <div className="text-xs text-base-content/60 mt-1">
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
      </div>

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
                      <span className="font-mono">
                        {formatEther((reserveBalance || 0n) + (treasury || 0n))} ETH
                      </span>
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
            <p className="py-4">
              Are you sure you want to drain all funds? This action cannot be undone.
            </p>
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
