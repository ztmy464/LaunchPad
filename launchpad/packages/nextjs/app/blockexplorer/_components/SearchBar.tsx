"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { isAddress, isHex } from "viem";
import { usePublicClient } from "wagmi";
import { useTargetNetwork } from "~~/hooks/scaffold-eth/useTargetNetwork";

export const SearchBar = () => {
  const [searchInput, setSearchInput] = useState("");
  const router = useRouter();
  const { targetNetwork } = useTargetNetwork();

  const client = usePublicClient({ chainId: targetNetwork.id });

  const handleSearch = async (event: React.FormEvent) => {
    event.preventDefault();
    
    // For networks with block explorers, redirect to external explorer
    if (targetNetwork.blockExplorers?.default.url) {
      if (isHex(searchInput) && searchInput.length === 66) {
        // Transaction hash
        window.open(`${targetNetwork.blockExplorers.default.url}/tx/${searchInput}`, "_blank");
        return;
      }
      if (isAddress(searchInput)) {
        window.open(`${targetNetwork.blockExplorers.default.url}/address/${searchInput}`, "_blank");
        return;
      }
    }
    
    // Fallback to local explorer for localhost
    if (isHex(searchInput)) {
      try {
        const tx = await client?.getTransaction({ hash: searchInput });
        if (tx) {
          router.push(`/blockexplorer/transaction/${searchInput}`);
          return;
        }
      } catch {
        // Transaction not found
      }
    }

    if (isAddress(searchInput)) {
      router.push(`/blockexplorer/address/${searchInput}`);
      return;
    }
  };

  return (
    <form onSubmit={handleSearch} className="flex items-center justify-end mb-5 space-x-3 mx-5">
      <input
        className="border-primary bg-base-100 text-base-content placeholder:text-base-content/50 p-2 mr-2 w-full md:w-1/2 lg:w-1/3 rounded-md shadow-md focus:outline-hidden focus:ring-2 focus:ring-accent"
        type="text"
        value={searchInput}
        placeholder="Search by hash or address"
        onChange={e => setSearchInput(e.target.value)}
      />
      <button className="btn btn-sm btn-primary" type="submit">
        Search
      </button>
    </form>
  );
};
