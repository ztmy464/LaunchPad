"use client";

import { DebugContracts } from "./_components/DebugContracts";
import type { NextPage } from "next";
import { useTargetNetwork } from "~~/hooks/scaffold-eth/useTargetNetwork";
import { mainnet, base, hardhat, foundry } from "viem/chains";

const Debug: NextPage = () => {
  const { targetNetwork } = useTargetNetwork();
  
  // Only allow debug page on local development networks
  const isLocalNetwork = targetNetwork.id === hardhat.id || targetNetwork.id === foundry.id;
  
  if (!isLocalNetwork) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center p-10 bg-base-200 rounded-xl max-w-md">
          <h1 className="text-2xl font-bold mb-4">Debug Unavailable</h1>
          <p className="text-neutral">
            The debug page is only available on local development networks.
          </p>
        </div>
      </div>
    );
  }

  return (
    <>
      <DebugContracts />
      <div className="text-center mt-8 bg-secondary p-10">
        <h1 className="text-4xl my-0">Debug Contracts</h1>
        <p className="text-neutral">
          You can debug & interact with your deployed contracts here.
          <br /> Check{" "}
          <code className="italic bg-base-300 text-base font-bold [word-spacing:-0.5rem] px-1">
            packages / nextjs / app / debug / page.tsx
          </code>{" "}
        </p>
      </div>
    </>
  );
};

export default Debug;
