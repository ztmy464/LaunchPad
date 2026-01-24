"use client";

import { useEffect, useState } from "react";
import { PaginationButton, SearchBar, TransactionsTable } from "./_components";
import type { NextPage } from "next";
import { hardhat, foundry } from "viem/chains";
import { useFetchBlocks } from "~~/hooks/scaffold-eth";
import { useTargetNetwork } from "~~/hooks/scaffold-eth/useTargetNetwork";

const BlockExplorer: NextPage = () => {
  const { blocks, transactionReceipts, currentPage, totalBlocks, setCurrentPage, error } = useFetchBlocks();
  const { targetNetwork } = useTargetNetwork();
  const [isLocalNetwork, setIsLocalNetwork] = useState(true);
  const [hasError, setHasError] = useState(false);

  useEffect(() => {
    // Check if we're on a local development network
    const isLocal = targetNetwork.id === hardhat.id || targetNetwork.id === foundry.id;
    setIsLocalNetwork(isLocal);
  }, [targetNetwork.id]);

  useEffect(() => {
    if (isLocalNetwork && error) {
      setHasError(true);
    }
  }, [isLocalNetwork, error]);

  // For production networks, show redirect to external explorer
  if (!isLocalNetwork) {
    return (
      <div className="container mx-auto my-10">
        <div className="flex flex-col items-center justify-center min-h-[50vh] text-center">
          <h1 className="text-3xl font-bold mb-4">Block Explorer</h1>
          <p className="text-lg mb-6 max-w-md">
            You are connected to <span className="font-semibold">{targetNetwork.name}</span>.
          </p>
          {targetNetwork.blockExplorers?.default.url ? (
            <div className="space-y-4">
              <p className="text-neutral">Use the search bar below or visit the official explorer:</p>
              <SearchBar />
              <a
                href={targetNetwork.blockExplorers.default.url}
                target="_blank"
                rel="noopener noreferrer"
                className="btn btn-primary btn-lg"
              >
                Open {targetNetwork.blockExplorers.default.name}
              </a>
            </div>
          ) : (
            <p className="text-neutral">No block explorer available for this network.</p>
          )}
        </div>
      </div>
    );
  }

  // Show error state for local network connection issues
  if (hasError) {
    return (
      <div className="container mx-auto my-10">
        <div className="flex flex-col items-center justify-center min-h-[50vh] text-center">
          <h1 className="text-3xl font-bold mb-4">Connection Error</h1>
          <p className="text-lg mb-4">Cannot connect to local blockchain.</p>
          <p className="text-neutral">
            Make sure you have run <code className="bg-base-300 px-2 py-1 rounded">yarn chain</code>
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="container mx-auto my-10">
      <SearchBar />
      <TransactionsTable blocks={blocks} transactionReceipts={transactionReceipts} />
      <PaginationButton currentPage={currentPage} totalItems={Number(totalBlocks)} setCurrentPage={setCurrentPage} />
    </div>
  );
};

export default BlockExplorer;
