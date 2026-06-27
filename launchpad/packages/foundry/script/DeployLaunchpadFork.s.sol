// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/TokenFactory.sol";
import "../contracts/CreatorFeeRouter.sol";

/**
 * @notice Deploy script for LaunchPad on Base Fork
 * @dev This script deploys the launchpad contracts with V2 integration
 *
 * Run with:
 *   yarn deploy --file DeployLaunchpadFork.s.sol
 */
contract DeployLaunchpadFork is ScaffoldETHDeploy {
    // Uniswap V2 addresses on Base (used when forking Base)
    address constant V2_ROUTER_BASE = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address constant V2_FACTORY_BASE = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;

    function run() external ScaffoldEthDeployerRunner {
        address v2Router = V2_ROUTER_BASE;
        address v2Factory = V2_FACTORY_BASE;

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

        console.log("");
        console.log("=== V2 Integration Enabled ===");
        console.log("Graduation threshold: 0.02 ETH (based on reserve balance)");
        console.log("After graduation, 'Create Pool' creates a Uniswap V2 pair");
        console.log("Token will be tradeable on Uniswap, Rainbow, and all DEX aggregators!");
        console.log("2% creator fee applies when trading via CreatorFeeRouter (your frontend)");
    }
}
