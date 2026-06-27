// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/TokenFactory.sol";
import "../contracts/CreatorFeeRouter.sol";

/**
 * @notice Deploy script for LaunchPad with Uniswap V2 integration
 * @dev Deploys TokenFactory and CreatorFeeRouter, links them to V2 Router
 *
 * For local testing with Base fork:
 *   anvil --fork-url $BASE_RPC
 *   forge script script/DeployLaunchpad.s.sol --rpc-url http://localhost:8545 --broadcast
 */
contract DeployLaunchpad is ScaffoldETHDeploy {
    // Uniswap V2 addresses on Base
    address constant V2_ROUTER_BASE = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address constant V2_FACTORY_BASE = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    
    // Uniswap V2 addresses on Mainnet (for reference)
    address constant V2_ROUTER_MAINNET = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant V2_FACTORY_MAINNET = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    function run() external ScaffoldEthDeployerRunner {
        // Get V2 addresses based on chain
        (address v2Router, address v2Factory) = _getV2Addresses();
        
        require(v2Router != address(0), "V2 Router not found for this chain");
        require(v2Factory != address(0), "V2 Factory not found for this chain");

        console.log("Deploying to chain:", block.chainid);
        console.log("V2 Router:", v2Router);
        console.log("V2 Factory:", v2Factory);

        // Deploy TokenFactory (no hook needed for V2)
        TokenFactory factory = new TokenFactory(address(0));
        console.log("TokenFactory deployed at:", address(factory));
        console.log("LaunchToken implementation at:", factory.tokenImplementation());

        // Deploy CreatorFeeRouter
        CreatorFeeRouter feeRouter = new CreatorFeeRouter(v2Router, v2Factory);
        console.log("CreatorFeeRouter deployed at:", address(feeRouter));

        // Link V2 Router to TokenFactory
        factory.setV2Router(v2Router);
        console.log("V2 Router linked to TokenFactory");

        // Link FeeRouter to TokenFactory
        factory.setFeeRouter(address(feeRouter));
        console.log("FeeRouter linked to TokenFactory");

        // Authorize TokenFactory to register tokens on FeeRouter
        feeRouter.setAuthorizedFactory(address(factory));
        console.log("TokenFactory authorized on FeeRouter");

        // Record deployments for frontend
        deployments.push(Deployment({name: "TokenFactory", addr: address(factory)}));
        deployments.push(Deployment({name: "CreatorFeeRouter", addr: address(feeRouter)}));
    }

    function _getV2Addresses() internal view returns (address router, address factory) {
        uint256 chainId = block.chainid;

        if (chainId == 8453 || chainId == 31337) {
            // Base or local fork of Base
            return (V2_ROUTER_BASE, V2_FACTORY_BASE);
        } else if (chainId == 1) {
            // Mainnet
            return (V2_ROUTER_MAINNET, V2_FACTORY_MAINNET);
        }

        // Unknown chain
        return (address(0), address(0));
    }
}
