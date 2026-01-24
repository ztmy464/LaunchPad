"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { RocketLaunchIcon, ArrowLeftIcon } from "@heroicons/react/24/outline";
import Link from "next/link";
import { useScaffoldWriteContract, useScaffoldEventHistory } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

const CreateToken: NextPage = () => {
  const router = useRouter();
  const { address: connectedAddress, isConnected } = useAccount();
  const [name, setName] = useState("");
  const [symbol, setSymbol] = useState("");
  const [isCreating, setIsCreating] = useState(false);

  const { writeContractAsync: createToken } = useScaffoldWriteContract("TokenFactory");

  // Watch for TokenLaunched events
  const { data: launchEvents } = useScaffoldEventHistory({
    contractName: "TokenFactory",
    eventName: "TokenLaunched",
    fromBlock: 0n,
    watch: true,
    filters: { creator: connectedAddress },
  });

  const handleCreate = async () => {
    if (!name.trim() || !symbol.trim()) {
      notification.error("Please enter both name and symbol");
      return;
    }

    setIsCreating(true);
    try {
      const tx = await createToken({
        functionName: "createToken",
        args: [name, symbol.toUpperCase()],
      });

      notification.success("Token created successfully!");

      // Wait a moment for the event to be indexed, then redirect
      setTimeout(() => {
        if (launchEvents && launchEvents.length > 0) {
          const latestToken = launchEvents[launchEvents.length - 1].args.token;
          router.push(`/token/${latestToken}`);
        } else {
          router.push("/");
        }
      }, 2000);
    } catch (error: any) {
      console.error("Error creating token:", error);
      notification.error(error.message || "Failed to create token");
    } finally {
      setIsCreating(false);
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
                  <div className="font-mono font-semibold">0.00001 ETH</div>
                </div>
                <div className="bg-base-200 rounded-lg p-4">
                  <div className="text-sm text-base-content/60">Graduation</div>
                  <div className="font-mono font-semibold">0.1 ETH Reserve</div>
                </div>
                <div className="bg-base-200 rounded-lg p-4">
                  <div className="text-sm text-base-content/60">Buy Fee</div>
                  <div className="font-mono font-semibold">1%</div>
                </div>
                <div className="bg-base-200 rounded-lg p-4">
                  <div className="text-sm text-base-content/60">Sell Fee</div>
                  <div className="font-mono font-semibold">2%</div>
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
                    For the first 60 seconds after launch, early buyers receive proportionally fewer tokens.
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
    </div>
  );
};

export default CreateToken;
