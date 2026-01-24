// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/TokenFactory.sol";
import "../contracts/TradeFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/**
 * @notice Deploy script for Token Launchpad contracts
 * @dev Deploys TokenFactory (which creates LaunchToken implementation internally)
 *      The TradeFeeHook requires address mining for correct hook flags - see HookMiner
 *
 * For local testing without V4:
 *   yarn deploy --file DeployLaunchpad.s.sol
 *
 * For mainnet/testnet with V4:
 *   1. First deploy the TradeFeeHook using CREATE2 with mined salt
 *   2. Then deploy TokenFactory with hook address
 */
contract DeployLaunchpad is ScaffoldETHDeploy {
    // Uniswap V4 PoolManager addresses by chain
    // See: https://docs.uniswap.org/contracts/v4/deployments
    address constant POOL_MANAGER_BASE = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant POOL_MANAGER_MAINNET = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POOL_MANAGER_SEPOLIA = address(0); // No V4 on Sepolia yet

    function run() external ScaffoldEthDeployerRunner {
        // For initial deployment without V4 integration, use zero address for hook
        // The factory will work, but graduated tokens won't have V4 pool integration yet
        address hookAddress = address(0);

        // Get PoolManager based on chain
        address poolManager = _getPoolManager();

        // If we have a pool manager and want to deploy hook, we need CREATE2 address mining
        // For now, just deploy the factory with placeholder hook
        if (poolManager != address(0)) {
            console.log("PoolManager found at:", poolManager);
            console.log("Note: TradeFeeHook requires CREATE2 address mining for proper deployment");
            console.log("For full V4 integration, deploy hook separately with mined address");
        }

        // Deploy TokenFactory
        // The factory deploys its own LaunchToken implementation internally
        TokenFactory factory = new TokenFactory(hookAddress);

        console.log("TokenFactory deployed at:", address(factory));
        console.log("LaunchToken implementation at:", factory.tokenImplementation());
        console.log("TradeFeeHook address:", hookAddress);

        // Record deployments for frontend
        deployments.push(Deployment({name: "TokenFactory", addr: address(factory)}));
    }

    function _getPoolManager() internal view returns (address) {
        uint256 chainId = block.chainid;

        if (chainId == 8453) {
            // Base
            return POOL_MANAGER_BASE;
        } else if (chainId == 1) {
            // Mainnet
            return POOL_MANAGER_MAINNET;
        } else if (chainId == 31337) {
            // Local - no real PoolManager
            return address(0);
        }

        // Unknown chain
        return address(0);
    }
}

/**
 * @notice Helper contract for mining V4 hook addresses
 * @dev The hook address must have specific bits set based on which callbacks are enabled
 *      This is typically done using CREATE2 with a mined salt
 *
 * Required hook flags for TradeFeeHook:
 *   - BEFORE_SWAP_FLAG (1 << 7 = 0x80)
 *   - BEFORE_SWAP_RETURNS_DELTA_FLAG (1 << 3 = 0x08)
 *
 * The address must have these bits set in the lowest 14 bits
 * Example valid address: 0x...0088 (has bits 7 and 3 set)
 */
contract HookAddressMiner {
    /**
     * @notice Compute CREATE2 address for hook deployment
     * @param deployer The deployer address
     * @param salt The salt for CREATE2
     * @param initCodeHash Hash of the hook's init code
     * @return predicted The predicted address
     */
    function computeAddress(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) public pure returns (address predicted) {
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
                    )
                )
            )
        );
    }

    /**
     * @notice Check if an address has the required hook flags
     * @param hookAddress The address to check
     * @return valid True if address has correct flags
     */
    function hasRequiredFlags(address hookAddress) public pure returns (bool) {
        uint160 addr = uint160(hookAddress);

        // Required flags for beforeSwap + beforeSwapReturnsDelta
        uint160 requiredFlags = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

        // Check that required flags are set
        return (addr & requiredFlags) == requiredFlags;
    }

    /**
     * @notice Find a salt that produces a valid hook address
     * @param deployer The deployer address
     * @param initCodeHash Hash of the hook's init code
     * @param startSalt Starting salt to search from
     * @param maxIterations Maximum iterations to try
     * @return salt The found salt (or 0 if not found)
     * @return hookAddress The resulting address
     */
    function findValidSalt(
        address deployer,
        bytes32 initCodeHash,
        uint256 startSalt,
        uint256 maxIterations
    ) public pure returns (bytes32 salt, address hookAddress) {
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(startSalt + i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);

            if (hasRequiredFlags(hookAddress)) {
                return (salt, hookAddress);
            }
        }

        // Not found in given iterations
        return (bytes32(0), address(0));
    }
}
