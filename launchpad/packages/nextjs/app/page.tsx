"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import type { NextPage } from "next";
import { formatEther } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { PlusCircleIcon, RocketLaunchIcon } from "@heroicons/react/24/outline";
import { LaunchTokenABI } from "~~/contracts/externalContracts";
import { useDeployedContractInfo, useScaffoldReadContract } from "~~/hooks/scaffold-eth";

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
] as const;

interface TokenInfo {
  address: `0x${string}`;
  name: string;
  symbol: string;
  totalSupply: bigint;
  treasury: bigint;
  graduated: boolean;
  currentPrice: bigint;
}

const TokenCard = ({ token, graduationThreshold }: { token: TokenInfo; graduationThreshold: bigint }) => {
  const progressPercent = graduationThreshold > 0n ? Number((token.treasury * 100n) / graduationThreshold) : 0;

  return (
    <Link href={`/token/${token.address}`}>
      <div className="card bg-base-100 shadow-xl hover:shadow-2xl transition-all cursor-pointer border border-base-300 hover:border-primary">
        <div className="card-body">
          <div className="flex justify-between items-start">
            <div>
              <h2 className="card-title text-xl">{token.name}</h2>
              <p className="text-base-content/60 font-mono">${token.symbol}</p>
            </div>
            {token.graduated ? (
              <div className="badge badge-success gap-1">
                <RocketLaunchIcon className="w-3 h-3" />
                Graduated
              </div>
            ) : (
              <div className="badge badge-warning">Bonding Curve</div>
            )}
          </div>

          <div className="mt-4 space-y-2">
            <div className="flex justify-between text-sm">
              <span className="text-base-content/60">Price</span>
              <span className="font-mono">{formatEther(token.currentPrice)} ETH</span>
            </div>
            <div className="flex justify-between text-sm">
              <span className="text-base-content/60">Supply</span>
              <span className="font-mono">{Number(token.totalSupply / BigInt(1e18)).toLocaleString()}</span>
            </div>
            <div className="flex justify-between text-sm">
              <span className="text-base-content/60">Treasury</span>
              <span className="font-mono">{formatEther(token.treasury)} ETH</span>
            </div>
          </div>

          {!token.graduated && (
            <div className="mt-4">
              <div className="flex justify-between text-xs mb-1">
                <span>Progress to Uniswap</span>
                <span>{Math.min(progressPercent, 100)}%</span>
              </div>
              <progress className="progress progress-primary w-full" value={Math.min(progressPercent, 100)} max="100" />
            </div>
          )}
        </div>
      </div>
    </Link>
  );
};

const Home: NextPage = () => {
  const [tokens, setTokens] = useState<TokenInfo[]>([]);
  const [loading, setLoading] = useState(true);

  // Get TokenFactory address
  const { data: tokenFactoryInfo } = useDeployedContractInfo({ contractName: "TokenFactory" });

  // Read config values from TokenFactory
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

  // Calculate display values with fallbacks
  const graduationDisplay = graduationThreshold ? formatEther(graduationThreshold) : "...";
  const buyFeePercent = buyFeeBps ? Number(buyFeeBps) / 100 : 1;
  const sellFeePercent = sellFeeBps ? Number(sellFeeBps) / 100 : 2;

  // Get total number of tokens
  const { data: totalTokens } = useScaffoldReadContract({
    contractName: "TokenFactory",
    functionName: "totalTokens",
  });

  // Get token addresses (paginated)
  const { data: tokenAddresses } = useScaffoldReadContract({
    contractName: "TokenFactory",
    functionName: "getTokensPaginated",
    args: [0n, 20n],
  });

  // Get token info from factory
  const { data: tokensInfo } = useScaffoldReadContract({
    contractName: "TokenFactory",
    functionName: "getTokensInfo",
    args: [tokenAddresses || []],
    query: {
      enabled: !!tokenAddresses && tokenAddresses.length > 0,
    },
  });

  // Get current prices for all tokens
  const priceReads = (tokenAddresses || []).map(addr => ({
    address: addr,
    abi: LaunchTokenABI,
    functionName: "getCurrentPrice" as const,
  }));

  const { data: prices } = useReadContracts({
    contracts: priceReads,
    query: {
      enabled: priceReads.length > 0,
    },
  });

  // Combine all data into token info
  useEffect(() => {
    if (tokenAddresses && tokensInfo && prices) {
      const [names, symbols, supplies, treasuries, graduatedFlags] = tokensInfo;
      const tokenList: TokenInfo[] = tokenAddresses.map((addr, i) => ({
        address: addr as `0x${string}`,
        name: names[i],
        symbol: symbols[i],
        totalSupply: supplies[i],
        treasury: treasuries[i],
        graduated: graduatedFlags[i],
        currentPrice: (prices[i]?.result as bigint) || 0n,
      }));
      setTokens(tokenList);
      setLoading(false);
    } else if (tokenAddresses && tokenAddresses.length === 0) {
      setLoading(false);
    }
  }, [tokenAddresses, tokensInfo, prices]);

  return (
    <div className="flex flex-col grow">
      {/* Hero Section */}
      <div className="bg-gradient-to-br from-primary/10 via-base-100 to-secondary/10 py-16">
        <div className="container mx-auto px-6">
          <div className="flex flex-col lg:flex-row items-center justify-between gap-8">
            <div className="max-w-xl">
              <p className="text-lg text-base-content/70 mb-6">
                Launch your token with a bonding curve. No initial liquidity needed. As people buy, the reserve fills
                up. At {graduationDisplay} ETH, your token graduates to Uniswap V4.
              </p>
              <div className="flex gap-4">
                <Link href="/create" className="btn btn-primary btn-lg gap-2">
                  <PlusCircleIcon className="w-6 h-6" />
                  Launch Token
                </Link>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Token List */}
      <div className="container mx-auto px-6 py-12">
        <div className="flex justify-between items-center mb-8">
          <h2 className="text-2xl font-bold">Launched Tokens</h2>
          <Link href="/create" className="btn btn-outline btn-sm gap-1">
            <PlusCircleIcon className="w-4 h-4" />
            New Token
          </Link>
        </div>

        {loading ? (
          <div className="flex justify-center py-12">
            <span className="loading loading-spinner loading-lg"></span>
          </div>
        ) : tokens.length === 0 ? (
          <div className="text-center py-12 bg-base-200 rounded-xl">
            <RocketLaunchIcon className="w-16 h-16 mx-auto mb-4 text-base-content/30" />
            <h3 className="text-xl font-semibold mb-2">No tokens yet</h3>
            <p className="text-base-content/60 mb-4">Be the first to launch a token!</p>
            <Link href="/create" className="btn btn-primary">
              Launch Token
            </Link>
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            {tokens.map(token => (
              <TokenCard key={token.address} token={token} graduationThreshold={graduationThreshold || 0n} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
};

export default Home;
