"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import type { NextPage } from "next";
import { formatEther, keccak256, toBytes } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { RocketLaunchIcon, ArrowLeftIcon, CheckCircleIcon, XCircleIcon, WalletIcon } from "@heroicons/react/24/outline";
import Link from "next/link";
import { useScaffoldWriteContract, useDeployedContractInfo, useTargetNetwork } from "~~/hooks/scaffold-eth";
import { notification, getBlockExplorerTxLink } from "~~/utils/scaffold-eth";

// ABI for TokenFactory config getters
const TokenFactoryConfigABI = [
  {
    type: "function",
    name: "getGraduationThreshold",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "pure",
  },
  {
    type: "function",
    name: "getCooldownPeriod",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "pure",
  },
  {
    type: "function",
    name: "getBuyFeeBps",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "pure",
  },
  {
    type: "function",
    name: "getSellFeeBps",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "pure",
  },
  {
    type: "function",
    name: "getBasePrice",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "pure",
  },
] as const;

// Event signature for TokenLaunched(address indexed token, string name, string symbol, address indexed creator, uint256 timestamp)
const TOKEN_LAUNCHED_TOPIC = keccak256(toBytes("TokenLaunched(address,string,string,address,uint256)"));

type CreationPhase = "idle" | "wallet" | "confirming" | "success" | "error";

const CreateToken: NextPage = () => {
  const router = useRouter();
  const { isConnected } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const [name, setName] = useState("");
  const [symbol, setSymbol] = useState("");
  const [creationPhase, setCreationPhase] = useState<CreationPhase>("idle");
  const [txHash, setTxHash] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const isCreating = creationPhase !== "idle";

  const { writeContractAsync: createToken } = useScaffoldWriteContract("TokenFactory");
  
  // Get TokenFactory address
  const { data: tokenFactoryInfo } = useDeployedContractInfo({ contractName: "TokenFactory" });
  
  // Read config values from TokenFactory
  const { data: basePrice } = useReadContract({
    address: tokenFactoryInfo?.address,
    abi: TokenFactoryConfigABI,
    functionName: "getBasePrice",
    query: { enabled: !!tokenFactoryInfo?.address },
  });

  const { data: graduationThreshold } = useReadContract({
    address: tokenFactoryInfo?.address,
    abi: TokenFactoryConfigABI,
    functionName: "getGraduationThreshold",
    query: { enabled: !!tokenFactoryInfo?.address },
  });

  const { data: buyFeeBps } = useReadContract({
    address: tokenFactoryInfo?.address,
    abi: TokenFactoryConfigABI,
    functionName: "getBuyFeeBps",
    query: { enabled: !!tokenFactoryInfo?.address },
  });

  const { data: sellFeeBps } = useReadContract({
    address: tokenFactoryInfo?.address,
    abi: TokenFactoryConfigABI,
    functionName: "getSellFeeBps",
    query: { enabled: !!tokenFactoryInfo?.address },
  });

  const { data: cooldownPeriod } = useReadContract({
    address: tokenFactoryInfo?.address,
    abi: TokenFactoryConfigABI,
    functionName: "getCooldownPeriod",
    query: { enabled: !!tokenFactoryInfo?.address },
  });

  // Calculate display values with fallbacks
  const basePriceDisplay = basePrice ? formatEther(basePrice) : "0.00001";
  const graduationDisplay = graduationThreshold ? formatEther(graduationThreshold) : "...";
  const buyFeePercent = buyFeeBps ? Number(buyFeeBps) / 100 : 1;
  const sellFeePercent = sellFeeBps ? Number(sellFeeBps) / 100 : 2;
  const cooldownSeconds = cooldownPeriod ? Number(cooldownPeriod) : 60;

  const handleCreate = async () => {
    if (!name.trim() || !symbol.trim()) {
      notification.error("Please enter both name and symbol");
      return;
    }

    // Reset state and start wallet phase
    setCreationPhase("wallet");
    setTxHash(null);
    setErrorMessage(null);

    try {
      const hash = await createToken(
        {
          functionName: "createToken",
          args: [name, symbol.toUpperCase()],
        },
        {
          onBlockConfirmation: (receipt) => {
            // Set success phase briefly before redirect
            setCreationPhase("success");

            // Find TokenLaunched event - topics[1] is the indexed token address
            const tokenLog = receipt.logs.find(
              (log) => log.topics[0] === TOKEN_LAUNCHED_TOPIC
            );

            // Small delay to show success state before redirect
            setTimeout(() => {
              if (tokenLog?.topics[1]) {
                // Extract address from 32-byte padded topic (last 40 hex chars = 20 bytes)
                const tokenAddress = `0x${tokenLog.topics[1].slice(-40)}`;
                router.push(`/token/${tokenAddress}`);
              } else {
                router.push("/");
              }
            }, 1000);
          },
        }
      );

      // Transaction submitted - move to confirming phase
      if (hash) {
        setTxHash(hash);
        setCreationPhase("confirming");
      }
    } catch (error: any) {
      // Check if user rejected the transaction
      const isUserRejection = 
        error.message?.includes("User rejected") || 
        error.message?.includes("user rejected") ||
        error.message?.includes("User denied") ||
        error.code === 4001;

      if (isUserRejection) {
        // Silent reset for user rejection
        setCreationPhase("idle");
      } else {
        // Show error modal for other errors
        setErrorMessage(error.message || "Failed to create token");
        setCreationPhase("error");
      }
    }
  };

  return (
    <div className="container mx-auto px-6 py-12 max-w-2xl">
      <Link href="/" className="btn btn-ghost btn-sm gap-2 mb-8">
        <ArrowLeftIcon className="w-4 h-4" />
        Back to Tokens
      </Link>

      <div className="card bg-base-100 shadow-xl">
        <div className="card-body">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-12 h-12 bg-primary/10 rounded-full flex items-center justify-center">
              <RocketLaunchIcon className="w-6 h-6 text-primary" />
            </div>
            <div>
              <h1 className="card-title text-2xl">Launch Your Token</h1>
              <p className="text-base-content/60">Create a new token with bonding curve liquidity</p>
            </div>
          </div>

          <div className="divider"></div>

          {!isConnected ? (
            <div className="alert alert-warning">
              <span>Please connect your wallet to create a token</span>
            </div>
          ) : (
            <div className="space-y-6">
              {/* Token Name */}
              <div className="form-control">
                <label className="label">
                  <span className="label-text font-semibold">Token Name</span>
                </label>
                <input
                  type="text"
                  placeholder="e.g., My Awesome Token"
                  className="input input-bordered w-full"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  disabled={isCreating}
                  maxLength={50}
                />
                <label className="label">
                  <span className="label-text-alt text-base-content/60">The full name of your token</span>
                </label>
              </div>

              {/* Token Symbol */}
              <div className="form-control">
                <label className="label">
                  <span className="label-text font-semibold">Token Symbol</span>
                </label>
                <input
                  type="text"
                  placeholder="e.g., MAT"
                  className="input input-bordered w-full font-mono uppercase"
                  value={symbol}
                  onChange={(e) => setSymbol(e.target.value.toUpperCase())}
                  disabled={isCreating}
                  maxLength={10}
                />
                <label className="label">
                  <span className="label-text-alt text-base-content/60">Short ticker symbol (2-10 characters)</span>
                </label>
              </div>

              {/* Info Cards */}
              <div className="grid grid-cols-2 gap-4">
                <div className="bg-base-200 rounded-lg p-4">
                  <div className="text-sm text-base-content/60">Starting Price</div>
                  <div className="font-mono font-semibold">{basePriceDisplay} ETH</div>
                </div>
                <div className="bg-base-200 rounded-lg p-4">
                  <div className="text-sm text-base-content/60">Graduation</div>
                  <div className="font-mono font-semibold">{graduationDisplay} ETH Reserve</div>
                </div>
                <div className="bg-base-200 rounded-lg p-4">
                  <div className="text-sm text-base-content/60">Buy Fee</div>
                  <div className="font-mono font-semibold">{buyFeePercent}%</div>
                </div>
                <div className="bg-base-200 rounded-lg p-4">
                  <div className="text-sm text-base-content/60">Sell Fee</div>
                  <div className="font-mono font-semibold">{sellFeePercent}%</div>
                </div>
              </div>

              {/* Sniper Protection Info */}
              <div className="alert alert-info">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" className="stroke-current shrink-0 w-6 h-6">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                <div>
                  <div className="font-semibold">Sniper Protection</div>
                  <div className="text-sm">
                    For the first {cooldownSeconds} seconds after launch, early buyers receive proportionally fewer tokens.
                    This prevents bots from sniping the launch.
                  </div>
                </div>
              </div>

              {/* Create Button */}
              <button
                className="btn btn-primary btn-lg w-full gap-2"
                onClick={handleCreate}
                disabled={isCreating || !name.trim() || !symbol.trim()}
              >
                {isCreating ? (
                  <>
                    <span className="loading loading-spinner"></span>
                    Creating Token...
                  </>
                ) : (
                  <>
                    <RocketLaunchIcon className="w-5 h-5" />
                    Launch Token
                  </>
                )}
              </button>

              {/* Preview */}
              {name && symbol && (
                <div className="mt-6 p-4 bg-base-200 rounded-lg">
                  <div className="text-sm text-base-content/60 mb-2">Preview</div>
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 bg-gradient-to-br from-primary to-secondary rounded-full flex items-center justify-center text-white font-bold">
                      {symbol.charAt(0)}
                    </div>
                    <div>
                      <div className="font-semibold">{name}</div>
                      <div className="text-sm text-base-content/60 font-mono">${symbol}</div>
                    </div>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      </div>

      {/* Creation Progress Modal */}
      {creationPhase !== "idle" && (
        <div className="modal modal-open">
          <div className="modal-box text-center max-w-md">
            {/* Progress Steps */}
            <ul className="steps steps-horizontal w-full mb-8">
              <li className="step step-primary">
                <span className="text-xs mt-1">Wallet</span>
              </li>
              <li className={`step ${creationPhase === "confirming" || creationPhase === "success" ? "step-primary" : ""}`}>
                <span className="text-xs mt-1">Confirming</span>
              </li>
              <li className={`step ${creationPhase === "success" ? "step-primary" : ""}`}>
                <span className="text-xs mt-1">Done</span>
              </li>
            </ul>

            {/* Phase-specific content */}
            {creationPhase === "wallet" && (
              <div className="py-4">
                <WalletIcon className="w-16 h-16 mx-auto text-primary mb-4" />
                <p className="text-lg font-semibold">Confirm in Wallet</p>
                <p className="text-sm text-base-content/60 mt-2">
                  Please confirm the transaction in your wallet to create your token.
                </p>
                <span className="loading loading-dots loading-md text-primary mt-4"></span>
              </div>
            )}

            {creationPhase === "confirming" && (
              <div className="py-4">
                <span className="loading loading-spinner loading-lg text-primary"></span>
                <p className="text-lg font-semibold mt-4">Transaction Submitted</p>
                <p className="text-sm text-base-content/60 mt-2">
                  Waiting for blockchain confirmation...
                </p>
                <p className="text-xs text-base-content/40 mt-1">
                  This may take 15-30 seconds on mainnet
                </p>
                {txHash && (
                  <a
                    href={getBlockExplorerTxLink(targetNetwork.id, txHash)}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="link link-primary text-sm mt-4 inline-block"
                  >
                    View on block explorer
                  </a>
                )}
              </div>
            )}

            {creationPhase === "success" && (
              <div className="py-4">
                <CheckCircleIcon className="w-16 h-16 mx-auto text-success mb-4" />
                <p className="text-lg font-semibold">Token Created!</p>
                <p className="text-sm text-base-content/60 mt-2">
                  Redirecting to your token page...
                </p>
              </div>
            )}

            {creationPhase === "error" && (
              <div className="py-4">
                <XCircleIcon className="w-16 h-16 mx-auto text-error mb-4" />
                <p className="text-lg font-semibold">Transaction Failed</p>
                <p className="text-sm text-base-content/60 mt-2 break-words max-w-sm mx-auto">
                  {errorMessage || "An unknown error occurred"}
                </p>
                <button
                  className="btn btn-primary mt-6"
                  onClick={() => {
                    setCreationPhase("idle");
                    setTxHash(null);
                    setErrorMessage(null);
                  }}
                >
                  Try Again
                </button>
              </div>
            )}
          </div>
          <div className="modal-backdrop bg-base-300/80"></div>
        </div>
      )}
    </div>
  );
};

export default CreateToken;
