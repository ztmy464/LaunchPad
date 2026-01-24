// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/TokenFactory.sol";
import "../contracts/SimplePool.sol";

/**
 * @notice Deploy script for Token Launchpad on Base Fork
 * @dev This script deploys the launchpad contracts for testing
 *
 * Run with:
 *   yarn deploy --file DeployLaunchpadFork.s.sol
 */
contract DeployLaunchpadFork is ScaffoldETHDeploy {

    function run() external ScaffoldEthDeployerRunner {
        // Deploy TokenFactory
        TokenFactory factory = new TokenFactory(address(0));
        console.log("TokenFactory deployed at:", address(factory));
        console.log("LaunchToken implementation at:", factory.tokenImplementation());

        // Deploy SimplePool for post-graduation trading
        SimplePool simplePool = new SimplePool();
        console.log("SimplePool deployed at:", address(simplePool));

        // Link SimplePool to TokenFactory for graduated pool creation
        factory.setSimplePool(address(simplePool));
        console.log("SimplePool set on TokenFactory");

        // Record deployments for frontend
        deployments.push(Deployment({name: "TokenFactory", addr: address(factory)}));
        deployments.push(Deployment({name: "SimplePool", addr: address(simplePool)}));

        console.log("");
        console.log("=== Graduation threshold: 0.1 ETH (based on reserve balance) ===");
        console.log("Buy enough tokens to fill reserve to 0.1 ETH to trigger graduation");
        console.log("(1% of buys go to creator earnings, 99% to reserve)");
        console.log("After graduation, use 'Create Pool' to create liquidity pool with price continuity");
    }
}
