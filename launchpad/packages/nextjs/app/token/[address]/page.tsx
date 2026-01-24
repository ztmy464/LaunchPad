"use client";

import { useState, useEffect } from "react";
import { useParams } from "next/navigation";
import Link from "next/link";
import type { NextPage } from "next";
import { formatEther, parseEther, maxUint256 } from "viem";
import { useAccount, useReadContract, useWriteContract, useBalance } from "wagmi";
import { ArrowLeftIcon, ArrowsRightLeftIcon, RocketLaunchIcon, ClockIcon, PlusIcon, BanknotesIcon } from "@heroicons/react/24/outline";
import { Address } from "@scaffold-ui/components";
import { LaunchTokenABI, SimplePoolABI, ERC20ApproveABI } from "~~/contracts/externalContracts";
import { useTargetNetwork } from "~~/hooks/scaffold-eth";
import { useDeployedContractInfo } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";
import { hardhat } from "viem/chains";

// Pool Swap Interface Component for Graduated Tokens
const PoolSwapInterface = ({ 
  tokenAddress, 
  symbol, 
  userBalance,
  refetchAllData 
}: { 
  tokenAddress: `0x${string}`; 
  symbol: string;
  userBalance: bigint | undefined;
  refetchAllData: () => void;
}) => {
  const { address: userAddress, isConnected } = useAccount();
  const [swapTab, setSwapTab] = useState<"buy" | "sell">("buy");
  const [swapAmount, setSwapAmount] = useState("");
  const [isSwapping, setIsSwapping] = useState(false);
  
  // Get SimplePool address
  const { data: simplePoolInfo } = useDeployedContractInfo({ contractName: "SimplePool" });
  const simplePoolAddress = simplePoolInfo?.address;
  
  const { data: ethBalance, refetch: refetchEthBalance } = useBalance({
    address: userAddress,
    query: { refetchInterval: 3000 },
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
  
  // Check token allowance for SimplePool
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: tokenAddress,
    abi: ERC20ApproveABI,
    functionName: "allowance",
    args: [userAddress || "0x0", simplePoolAddress || "0x0"],
    query: { enabled: !!userAddress && !!simplePoolAddress },
  });
  
  const { writeContractAsync } = useWriteContract();
  
  // Create Pool
  const handleCreatePool = async () => {
    if (!simplePoolAddress || !userBalance || userBalance === 0n) {
      notification.error("You need tokens to create the pool");
      return;
    }
    
    setIsSwapping(true);
    try {
      // Use half of tokens for liquidity
      const tokensForLiquidity = userBalance / 2n;
      const ethForLiquidity = parseEther("0.01"); // 0.01 ETH for initial liquidity
      
      // Approve tokens
      if ((allowance || 0n) < tokensForLiquidity) {
        notification.info("Approving tokens...");
        await writeContractAsync({
          address: tokenAddress,
          abi: ERC20ApproveABI,
          functionName: "approve",
          args: [simplePoolAddress, maxUint256],
        });
        await refetchAllowance();
      }
      
      notification.info("Creating pool...");
      await writeContractAsync({
        address: simplePoolAddress,
        abi: SimplePoolABI,
        functionName: "createPool",
        args: [tokenAddress, tokensForLiquidity],
        value: ethForLiquidity,
      });
      
      notification.success("Pool created successfully!");
      refetchHasPool();
      refetchReserves();
      refetchAllData();
    } catch (error: any) {
      console.error("Create pool error:", error);
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
      refetchReserves();
      refetchEthBalance();
      refetchAllData();
    } catch (error: any) {
      console.error("Buy error:", error);
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
      refetchReserves();
      refetchEthBalance();
      refetchAllData();
    } catch (error: any) {
      console.error("Sell error:", error);
      notification.error(error.message || "Sell failed");
    } finally {
      setIsSwapping(false);
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
        
        {isConnected ? (
          <>
            <button
              className="btn btn-primary w-full gap-2"
              onClick={handleCreatePool}
              disabled={isSwapping || !userBalance || userBalance === 0n}
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
              Creates a liquidity pool with 50% of your tokens and 0.01 ETH
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
  
  return (
    <div className="space-y-4">
      <div className="alert alert-success">
        <RocketLaunchIcon className="w-5 h-5" />
        <div>
          <div className="font-semibold">Trading on Pool!</div>
          <div className="text-sm">1% buy fee / 2% sell fee</div>
        </div>
      </div>
      
      {/* Pool Stats */}
      <div className="bg-base-200 rounded-lg p-3">
        <div className="text-xs text-base-content/60 mb-1">Pool Reserves</div>
        <div className="grid grid-cols-2 gap-2 text-sm font-mono">
          <div>{formatEther(ethReserve).slice(0, 8)} ETH</div>
          <div>{Number(tokenReserve / BigInt(1e18)).toLocaleString()} {symbol}</div>
        </div>
      </div>
      
      {!isConnected ? (
        <div className="alert alert-warning">Connect wallet to trade</div>
      ) : (
        <>
          {/* Tab Buttons */}
          <div className="tabs tabs-boxed">
            <button
              className={`tab flex-1 ${swapTab === "buy" ? "tab-active" : ""}`}
              onClick={() => { setSwapTab("buy"); setSwapAmount(""); }}
            >
              Buy
            </button>
            <button
              className={`tab flex-1 ${swapTab === "sell" ? "tab-active" : ""}`}
              onClick={() => { setSwapTab("sell"); setSwapAmount(""); }}
            >
              Sell
            </button>
          </div>
          
          {/* Amount Input */}
          <div className="form-control">
            <label className="label">
              <span className="label-text">
                {swapTab === "buy" ? "ETH Amount" : "Token Amount"}
              </span>
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
              onChange={(e) => setSwapAmount(e.target.value)}
              disabled={isSwapping}
              step="0.001"
              min="0"
            />
          </div>
          
          {/* Quick Amount Buttons */}
          <div className="flex gap-2">
            {swapTab === "buy" ? (
              <>
                <button className="btn btn-xs btn-outline" onClick={() => setSwapAmount("0.001")}>0.001</button>
                <button className="btn btn-xs btn-outline" onClick={() => setSwapAmount("0.01")}>0.01</button>
                <button className="btn btn-xs btn-outline" onClick={() => setSwapAmount("0.1")}>0.1</button>
              </>
            ) : (
              <>
                <button className="btn btn-xs btn-outline" onClick={() => userBalance && setSwapAmount(formatEther(userBalance / 4n))}>25%</button>
                <button className="btn btn-xs btn-outline" onClick={() => userBalance && setSwapAmount(formatEther(userBalance / 2n))}>50%</button>
                <button className="btn btn-xs btn-outline" onClick={() => userBalance && setSwapAmount(formatEther(userBalance))}>Max</button>
              </>
            )}
          </div>
          
          {/* Estimate */}
          <div className="bg-base-200 rounded-lg p-3">
            <div className="text-sm text-base-content/60">You will receive (approx)</div>
            <div className="font-mono font-semibold text-lg">
              {swapTab === "buy"
                ? `${estimatedBuyTokens !== undefined ? (Number(estimatedBuyTokens) / 1e18).toFixed(4) : "0"} ${symbol}`
                : `${estimatedSellEth !== undefined ? Number(formatEther(estimatedSellEth)).toFixed(4) : "0"} ETH`}
            </div>
            <div className="text-xs text-base-content/60 mt-1">
              {swapTab === "buy" ? "1% fee applied" : "2% fee applied"}
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
  const [amount, setAmount] = useState("");
  const [isTransacting, setIsTransacting] = useState(false);
  const [isWithdrawing, setIsWithdrawing] = useState(false);
  const [cooldownTime, setCooldownTime] = useState(0);

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

  const { data: cooldownRemaining, refetch: refetchCooldown } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "cooldownRemaining",
    query: { refetchInterval: 1000 },
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
  };

  // Estimate functions
  const ethAmountWei = amount ? parseEther(amount) : 0n;
  const tokenAmountWei = amount ? parseEther(amount) : 0n;

  const { data: estimatedTokens } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "estimateBuy",
    args: [ethAmountWei],
    query: { enabled: activeTab === "buy" && ethAmountWei > 0n },
  });

  const { data: estimatedEth } = useReadContract({
    address: tokenAddress,
    abi: LaunchTokenABI,
    functionName: "estimateSell",
    args: [tokenAmountWei],
    query: { enabled: activeTab === "sell" && tokenAmountWei > 0n },
  });

  // Write functions
  const { writeContractAsync } = useWriteContract();

  // Cooldown timer
  useEffect(() => {
    if (cooldownRemaining !== undefined) {
      setCooldownTime(Number(cooldownRemaining));
    }
  }, [cooldownRemaining]);

  useEffect(() => {
    const timer = setInterval(() => {
      setCooldownTime((prev) => Math.max(0, prev - 1));
      if (cooldownTime === 1) {
        refetchCooldown();
      }
    }, 1000);
    return () => clearInterval(timer);
  }, [cooldownTime, refetchCooldown]);

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
      console.error("Buy error:", error);
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
      console.error("Sell error:", error);
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
      console.error("Withdraw error:", error);
      notification.error(error.message || "Withdrawal failed");
    } finally {
      setIsWithdrawing(false);
    }
  };

  // Check if current user is the creator
  const isCreator = userAddress && creator && userAddress.toLowerCase() === creator.toLowerCase();

  // Graduation threshold - match BondingCurveMath.sol (based on reserveBalance, not treasury)
  const GRADUATION_THRESHOLD = 0.1;
  const progressPercent = reserveBalance ? Number((reserveBalance * 100n) / BigInt(GRADUATION_THRESHOLD * 1e18)) : 0;

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
                  <div className="font-mono font-semibold">
                    {currentPrice ? formatEther(currentPrice) : "0"} ETH
                  </div>
                </div>
                <div className="bg-base-200 rounded-lg p-3">
                  <div className="text-xs text-base-content/60">Supply</div>
                  <div className="font-mono font-semibold">
                    {totalSupply ? Number(totalSupply / BigInt(1e18)).toLocaleString() : "0"}
                  </div>
                </div>
                <div className="bg-base-200 rounded-lg p-3">
                  <div className="text-xs text-base-content/60">Your Balance</div>
                  <div className="font-mono font-semibold">
                    {userBalance ? Number(userBalance / BigInt(1e18)).toLocaleString() : "0"}
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
                  <div className="text-xs text-base-content/50 mt-1">From 1% buy / 2% sell fees</div>
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
                    <span>{GRADUATION_THRESHOLD} ETH to graduate</span>
                  </div>
                </div>
              )}

              {cooldownTime > 0 && (
                <div className="alert alert-warning mt-4">
                  <ClockIcon className="w-5 h-5" />
                  <div>
                    <div className="font-semibold">Sniper Protection Active</div>
                    <div className="text-sm">
                      {cooldownTime}s remaining. Buying now gives you proportionally fewer tokens.
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
                    onClick={() => { setActiveTab("buy"); setAmount(""); }}
                  >
                    Buy
                  </button>
                  <button
                    className={`tab flex-1 ${activeTab === "sell" ? "tab-active" : ""}`}
                    onClick={() => { setActiveTab("sell"); setAmount(""); }}
                  >
                    Sell
                  </button>
                </div>

                <div className="form-control">
                  <label className="label">
                    <span className="label-text">
                      {activeTab === "buy" ? "ETH Amount" : "Token Amount"}
                    </span>
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
                    onChange={(e) => setAmount(e.target.value)}
                    disabled={isTransacting}
                    step="0.001"
                    min="0"
                  />
                </div>

                <div className="flex gap-2 mt-2">
                  {activeTab === "buy" ? (
                    <>
                      <button className="btn btn-xs btn-outline" onClick={() => setAmount("0.001")}>0.001</button>
                      <button className="btn btn-xs btn-outline" onClick={() => setAmount("0.01")}>0.01</button>
                      <button className="btn btn-xs btn-outline" onClick={() => setAmount("0.1")}>0.1</button>
                    </>
                  ) : (
                    <>
                      <button className="btn btn-xs btn-outline" onClick={() => userBalance && setAmount(formatEther(userBalance / 4n))}>25%</button>
                      <button className="btn btn-xs btn-outline" onClick={() => userBalance && setAmount(formatEther(userBalance / 2n))}>50%</button>
                      <button className="btn btn-xs btn-outline" onClick={() => userBalance && setAmount(formatEther(userBalance))}>Max</button>
                    </>
                  )}
                </div>

                <div className="bg-base-200 rounded-lg p-3 mt-4">
                  <div className="text-sm text-base-content/60">You will receive (approx)</div>
                  <div className="font-mono font-semibold text-lg">
                    {activeTab === "buy"
                      ? `${estimatedTokens !== undefined ? (Number(estimatedTokens) / 1e18).toFixed(4) : "0"} ${symbol || "tokens"}`
                      : `${estimatedEth !== undefined ? Number(formatEther(estimatedEth)).toFixed(4) : "0"} ETH`}
                  </div>
                  <div className="text-xs text-base-content/60 mt-1">
                    {activeTab === "buy" ? "1% fee applied" : "2% fee applied"}
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
    </div>
  );
};

export default TokenPage;
