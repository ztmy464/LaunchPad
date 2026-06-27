// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/TokenFactory.sol";
import "../contracts/TradeFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/**
 * @notice Production deployment script for LaunchPad on Base Mainnet
 * @dev Deploys:
 *      1. TradeFeeHook with CREATE2 (mined address with correct hook flags)
 *      2. TokenFactory with the deployed hook
 *
 * Prerequisites:
 *   - Set DEPLOYER_PRIVATE_KEY in .env
 *   - Ensure deployer has enough ETH on Base
 *
 * Run with:
 *   forge script script/DeployBase.s.sol --rpc-url base --broadcast --verify
 */
contract DeployBase is ScaffoldETHDeploy {
    // ============ Base Mainnet V4 Addresses ============
    // https://docs.uniswap.org/contracts/v4/deployments
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant QUOTER = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;
    address constant STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Hook flags for TradeFeeHook: beforeSwap + beforeSwapReturnsDelta
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    function run() external ScaffoldEthDeployerRunner {
        // Verify we're on Base mainnet
        require(block.chainid == 8453, "This script is for Base mainnet (chainId 8453)");
        
        // Verify PoolManager exists
        require(_isV4Available(), "V4 PoolManager not found on Base");
        console.log("V4 PoolManager verified at:", POOL_MANAGER);

        // Step 1: Deploy TradeFeeHook with CREATE2 (mined address)
        console.log("Mining hook address with correct flags...");
        console.log("Required flags: BEFORE_SWAP (0x80) | BEFORE_SWAP_RETURNS_DELTA (0x08)");
        
        address hookAddress = _deployHookWithCreate2();
        console.log("TradeFeeHook deployed at:", hookAddress);
        
        // Verify hook address has correct flags set
        uint160 hookFlags = uint160(hookAddress) & Hooks.ALL_HOOK_MASK;
        require((hookFlags & HOOK_FLAGS) == HOOK_FLAGS, "Invalid hook address flags");
        console.log("Hook address verified with correct flags");

        // Step 2: Deploy TokenFactory with hook
        TokenFactory factory = new TokenFactory(hookAddress);
        console.log("TokenFactory deployed at:", address(factory));
        console.log("LaunchToken implementation at:", factory.tokenImplementation());

        // Record deployments for frontend
        deployments.push(Deployment({name: "TokenFactory", addr: address(factory)}));
        deployments.push(Deployment({name: "TradeFeeHook", addr: hookAddress}));
        
        // Record V4 addresses for frontend reference
        deployments.push(Deployment({name: "PoolManager", addr: POOL_MANAGER}));
        deployments.push(Deployment({name: "PositionManager", addr: POSITION_MANAGER}));
        deployments.push(Deployment({name: "UniversalRouter", addr: UNIVERSAL_ROUTER}));
        deployments.push(Deployment({name: "Quoter", addr: QUOTER}));
        deployments.push(Deployment({name: "Permit2", addr: PERMIT2}));

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Network: Base Mainnet");
        console.log("TokenFactory:", address(factory));
        console.log("TradeFeeHook:", hookAddress);
        console.log("");
        console.log("Graduation threshold: 0.1 ETH");
        console.log("Buy fee: 1% | Sell fee: 2%");
    }

    function _isV4Available() internal view returns (bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(POOL_MANAGER)
        }
        return codeSize > 0;
    }

    function _deployHookWithCreate2() internal returns (address) {
        // Get the creation code for TradeFeeHook
        // The hook is constructed with PoolManager and factory (factory set later via setFactory)
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), address(0));
        
        // Mine a salt that produces an address with correct hook flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, // Standard CREATE2 deployer
            HOOK_FLAGS,
            type(TradeFeeHook).creationCode,
            constructorArgs
        );

        console.log("Found valid hook address:", hookAddress);
        console.log("Using salt:", vm.toString(salt));

        // Deploy with CREATE2 via standard deployer
        bytes memory creationCode = abi.encodePacked(
            type(TradeFeeHook).creationCode,
            constructorArgs
        );

        // Use vm.broadcast to deploy via CREATE2
        address deployed;
        assembly {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }

        require(deployed == hookAddress, "Hook address mismatch - salt mining failed");
        require(deployed != address(0), "Hook deployment failed");
        
        return deployed;
    }

    // Standard CREATE2 deployer address (same on all chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
}
