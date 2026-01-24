"use client";

import { useState, useEffect } from "react";
import Link from "next/link";
import type { NextPage } from "next";
import { formatEther } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { RocketLaunchIcon, PlusCircleIcon } from "@heroicons/react/24/outline";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { LaunchTokenABI } from "~~/contracts/externalContracts";

interface TokenInfo {
  address: `0x${string}`;
  name: string;
  symbol: string;
  totalSupply: bigint;
  treasury: bigint;
  graduated: boolean;
  currentPrice: bigint;
}

const TokenCard = ({ token }: { token: TokenInfo }) => {
  const progressPercent = Number((token.treasury * 100n) / BigInt(0.1 * 1e18));

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
              <progress
                className="progress progress-primary w-full"
                value={Math.min(progressPercent, 100)}
                max="100"
              />
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
  const priceReads = (tokenAddresses || []).map((addr) => ({
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
        address: addr,
        name: names[i],
        symbol: symbols[i],
        totalSupply: supplies[i],
        treasury: treasuries[i],
        graduated: graduatedFlags[i],
        currentPrice: prices[i]?.result as bigint || 0n,
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
              <h1 className="text-5xl font-bold mb-4">
                Token <span className="text-primary">Launchpad</span>
              </h1>
              <p className="text-lg text-base-content/70 mb-6">
                Launch your token with a bonding curve. No initial liquidity needed.
                As people buy, the reserve fills up. At 0.1 ETH, your token graduates to Uniswap V4.
              </p>
              <div className="flex gap-4">
                <Link href="/create" className="btn btn-primary btn-lg gap-2">
                  <PlusCircleIcon className="w-6 h-6" />
                  Launch Token
                </Link>
              </div>
            </div>
            <div className="stats shadow bg-base-100">
              <div className="stat">
                <div className="stat-title">Total Tokens</div>
                <div className="stat-value text-primary">{totalTokens?.toString() || "0"}</div>
                <div className="stat-desc">Launched on platform</div>
              </div>
              <div className="stat">
                <div className="stat-title">Buy Fee</div>
                <div className="stat-value text-secondary">1%</div>
                <div className="stat-desc">Goes to treasury</div>
              </div>
              <div className="stat">
                <div className="stat-title">Sell Fee</div>
                <div className="stat-value text-accent">2%</div>
                <div className="stat-desc">Goes to treasury</div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* How It Works */}
      <div className="bg-base-200 py-12">
        <div className="container mx-auto px-6">
          <h2 className="text-2xl font-bold mb-8 text-center">How It Works</h2>
          <div className="grid grid-cols-1 md:grid-cols-4 gap-6">
            <div className="text-center">
              <div className="w-12 h-12 bg-primary rounded-full flex items-center justify-center mx-auto mb-3 text-primary-content font-bold">
                1
              </div>
              <h3 className="font-semibold mb-2">Create Token</h3>
              <p className="text-sm text-base-content/60">Enter name & symbol. Your token launches instantly.</p>
            </div>
            <div className="text-center">
              <div className="w-12 h-12 bg-primary rounded-full flex items-center justify-center mx-auto mb-3 text-primary-content font-bold">
                2
              </div>
              <h3 className="font-semibold mb-2">Bonding Curve</h3>
              <p className="text-sm text-base-content/60">Buy & sell against the curve. Price rises with demand.</p>
            </div>
            <div className="text-center">
              <div className="w-12 h-12 bg-primary rounded-full flex items-center justify-center mx-auto mb-3 text-primary-content font-bold">
                3
              </div>
              <h3 className="font-semibold mb-2">Build Reserve</h3>
              <p className="text-sm text-base-content/60">Reserve grows. At 0.1 ETH, graduation begins.</p>
            </div>
            <div className="text-center">
              <div className="w-12 h-12 bg-primary rounded-full flex items-center justify-center mx-auto mb-3 text-primary-content font-bold">
                4
              </div>
              <h3 className="font-semibold mb-2">Graduate to Uniswap</h3>
              <p className="text-sm text-base-content/60">Reserve seeds V4 pool. Real liquidity, real trading.</p>
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
            {tokens.map((token) => (
              <TokenCard key={token.address} token={token} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
};

export default Home;
