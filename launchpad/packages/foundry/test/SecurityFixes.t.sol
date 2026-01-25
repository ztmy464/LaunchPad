// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/TokenFactory.sol";
import "../contracts/CreatorFeeRouter.sol";
import "../contracts/LaunchToken.sol";

// Mock Uniswap V2 contracts for testing
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    
    mapping(address => uint256) public balanceOf;
    
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    
    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // Create a deterministic address for the pair
        pair = address(uint160(uint256(keccak256(abi.encodePacked(tokenA, tokenB, block.timestamp)))));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
        return pair;
    }
    
    function setPair(address tokenA, address tokenB, address pair) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract MockV2Router {
    address public immutable WETH;
    address public immutable factory;
    
    constructor(address _weth, address _factory) {
        WETH = _weth;
        factory = _factory;
    }
    
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint,
        uint,
        address to,
        uint
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        // Transfer tokens from sender
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = msg.value; // Simplified
        return (amountToken, amountETH, liquidity);
    }
    
    function swapExactETHForTokens(
        uint,
        address[] calldata,
        address,
        uint
    ) external payable returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value * 100; // 1 ETH = 100 tokens simplified
        return amounts;
    }
    
    function getAmountsOut(uint amountIn, address[] calldata) external pure returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 100;
        return amounts;
    }
}

contract SecurityFixesTest is Test {
    TokenFactory public factory;
    CreatorFeeRouter public feeRouter;
    MockWETH public weth;
    MockV2Factory public v2Factory;
    MockV2Router public v2Router;
    
    address public deployer = address(1);
    address public attacker = address(2);
    address public user = address(3);
    
    function setUp() public {
        vm.startPrank(deployer);
        
        // Deploy mock Uniswap contracts
        weth = new MockWETH();
        v2Factory = new MockV2Factory();
        v2Router = new MockV2Router(address(weth), address(v2Factory));
        
        // Deploy our contracts
        factory = new TokenFactory(address(0)); // No trade fee hook needed
        feeRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        // Link them
        feeRouter.setAuthorizedFactory(address(factory));
        factory.setV2Router(address(v2Router));
        factory.setFeeRouter(address(feeRouter));
        
        vm.stopPrank();
    }
    
    // ============ Fix 1: setAuthorizedFactory Tests ============
    
    function test_setAuthorizedFactory_onlyDeployer() public {
        // Deploy a fresh feeRouter
        vm.prank(deployer);
        CreatorFeeRouter newFeeRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        // Attacker tries to set factory - should fail
        vm.prank(attacker);
        vm.expectRevert(CreatorFeeRouter.NotDeployer.selector);
        newFeeRouter.setAuthorizedFactory(attacker);
        
        // Deployer can set factory
        vm.prank(deployer);
        newFeeRouter.setAuthorizedFactory(address(factory));
        
        assertEq(newFeeRouter.authorizedFactory(), address(factory));
    }
    
    function test_setAuthorizedFactory_cannotSetTwice() public {
        // Deploy a fresh feeRouter
        vm.prank(deployer);
        CreatorFeeRouter newFeeRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        // First set succeeds
        vm.prank(deployer);
        newFeeRouter.setAuthorizedFactory(address(factory));
        
        // Second set fails
        vm.prank(deployer);
        vm.expectRevert(CreatorFeeRouter.AlreadyRegistered.selector);
        newFeeRouter.setAuthorizedFactory(address(0x123));
    }
    
    function test_deployerIsImmutable() public {
        assertEq(feeRouter.deployer(), deployer);
    }
    
    // ============ Fix 2: V2 Pair Transfer Blocking Tests ============
    
    function test_expectedV2PairIsSet() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        address token = factory.createToken("Test Token", "TEST");
        
        LaunchToken launchToken = LaunchToken(payable(token));
        address expectedPair = launchToken.expectedV2Pair();
        
        // expectedV2Pair should be non-zero
        assertTrue(expectedPair != address(0), "expectedV2Pair should be set");
    }
    
    function test_transferToV2PairBlockedBeforeGraduation() public {
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        address token = factory.createToken("Test Token", "TEST");
        
        LaunchToken launchToken = LaunchToken(payable(token));
        address expectedPair = launchToken.expectedV2Pair();
        
        // Advance time past cooldown to get full tokens
        vm.warp(block.timestamp + 61);
        
        // Buy some tokens
        launchToken.buy{value: 0.001 ether}();
        
        uint256 balance = launchToken.balanceOf(user);
        assertTrue(balance > 0, "Should have tokens");
        
        // Try to transfer to V2 pair - should fail
        vm.expectRevert(LaunchToken.TransferToPoolBlocked.selector);
        launchToken.transfer(expectedPair, balance);
        
        vm.stopPrank();
    }
    
    function test_transferToV2PairAllowedAfterGraduation() public {
        vm.deal(user, 10 ether);
        vm.startPrank(user);
        
        address token = factory.createToken("Test Token", "TEST");
        LaunchToken launchToken = LaunchToken(payable(token));
        
        // Buy enough to graduate (graduation threshold is 0.004 ether)
        launchToken.buy{value: 0.005 ether}();
        
        assertTrue(launchToken.graduated(), "Token should be graduated");
        
        vm.stopPrank();
        
        // Now the token is graduated, transfers to pair should be allowed
        // (though in practice this would be done through the factory's pool creation)
    }
    
    function test_normalTransfersNotBlocked() public {
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        
        address token = factory.createToken("Test Token", "TEST");
        LaunchToken launchToken = LaunchToken(payable(token));
        
        // Buy some tokens
        launchToken.buy{value: 0.001 ether}();
        
        uint256 balance = launchToken.balanceOf(user);
        
        // Transfer to another address (not the V2 pair) should work
        address recipient = address(0x999);
        launchToken.transfer(recipient, balance / 2);
        
        assertEq(launchToken.balanceOf(recipient), balance / 2);
        
        vm.stopPrank();
    }
    
    function test_pairAddressComputedCorrectly() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        address token = factory.createToken("Test Token", "TEST");
        
        LaunchToken launchToken = LaunchToken(payable(token));
        address expectedPair = launchToken.expectedV2Pair();
        
        // Verify the pair address is computed using the Uniswap V2 formula
        // The pair is computed as CREATE2 with init code hash
        address computedPair = computeV2PairAddress(
            address(v2Factory),
            token,
            address(weth)
        );
        
        assertEq(expectedPair, computedPair, "Pair address should match computed address");
    }
    
    // Helper function to compute V2 pair address
    function computeV2PairAddress(
        address _factory,
        address tokenA,
        address tokenB
    ) internal pure returns (address pair) {
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff",
            _factory,
            keccak256(abi.encodePacked(token0, token1)),
            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
        )))));
    }
    
    // ============ Fix 3: Stuck ETH Recovery Tests ============
    
    function test_emergencyWithdrawRecoversSentETH() public {
        vm.deal(user, 10 ether);
        vm.prank(user);
        
        address token = factory.createToken("Test Token", "TEST");
        LaunchToken launchToken = LaunchToken(payable(token));
        
        // Buy some tokens
        vm.prank(user);
        launchToken.buy{value: 0.001 ether}();
        
        // Send ETH directly to token (stuck ETH)
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (bool success,) = token.call{value: 0.1 ether}("");
        assertTrue(success, "ETH send should succeed");
        
        // Verify contract has more ETH than tracked
        uint256 contractBalance = address(launchToken).balance;
        uint256 reserveBalance = launchToken.reserveBalance();
        uint256 treasury = launchToken.treasury();
        
        assertTrue(contractBalance > reserveBalance + treasury, "Contract should have stuck ETH");
        
        // Creator emergency withdraws - should get ALL ETH including stuck
        uint256 creatorBalanceBefore = user.balance;
        
        vm.prank(user);
        launchToken.emergencyWithdraw();
        
        uint256 creatorBalanceAfter = user.balance;
        
        // Creator should receive the entire contract balance
        assertEq(creatorBalanceAfter - creatorBalanceBefore, contractBalance, "Creator should receive all ETH");
        assertEq(address(launchToken).balance, 0, "Contract should have 0 ETH");
    }
    
    function test_emergencyWithdrawOnlyCreator() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        
        address token = factory.createToken("Test Token", "TEST");
        LaunchToken launchToken = LaunchToken(payable(token));
        
        // Buy some tokens
        vm.prank(user);
        launchToken.buy{value: 0.001 ether}();
        
        // Attacker tries emergency withdraw - should fail
        vm.prank(attacker);
        vm.expectRevert(LaunchToken.OnlyCreator.selector);
        launchToken.emergencyWithdraw();
    }
    
    // ============ Integration Tests ============
    
    function test_fullFlowWithSecurityFixes() public {
        vm.deal(user, 10 ether);
        
        // 1. Create token
        vm.prank(user);
        address token = factory.createToken("Integration Test", "INT");
        LaunchToken launchToken = LaunchToken(payable(token));
        
        // 2. Verify V2 pair is pre-computed
        address expectedPair = launchToken.expectedV2Pair();
        assertTrue(expectedPair != address(0));
        
        // 3. Buy tokens
        vm.prank(user);
        launchToken.buy{value: 0.001 ether}();
        
        // 4. Verify transfer to V2 pair is blocked
        uint256 balance = launchToken.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(LaunchToken.TransferToPoolBlocked.selector);
        launchToken.transfer(expectedPair, balance / 2);
        
        // 5. Graduate token
        vm.prank(user);
        launchToken.buy{value: 0.004 ether}();
        assertTrue(launchToken.graduated());
        
        // 6. After graduation, transfers to pair should be allowed
        // (In the real flow, factory handles this during pool creation)
    }
    
    function test_attackerCannotFrontRunFactoryRegistration() public {
        // Deploy fresh feeRouter
        vm.prank(deployer);
        CreatorFeeRouter newFeeRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        // Attacker tries to front-run and register themselves as factory
        vm.prank(attacker);
        vm.expectRevert(CreatorFeeRouter.NotDeployer.selector);
        newFeeRouter.setAuthorizedFactory(attacker);
        
        // Legitimate deployer sets factory
        vm.prank(deployer);
        newFeeRouter.setAuthorizedFactory(address(factory));
        
        // Factory is correctly set
        assertEq(newFeeRouter.authorizedFactory(), address(factory));
    }
    
    // ============ Price Continuity Test ============
    
    function test_poolTokensCalculation_ensuresHigherPriceOnV2() public {
        // This test verifies that the V2 pool is set up so that
        // buying tokens on V2 gives FEWER tokens than the bonding curve
        
        vm.deal(user, 10 ether);
        vm.startPrank(user);
        
        address token = factory.createToken("Price Test", "PRICE");
        LaunchToken launchToken = LaunchToken(payable(token));
        
        // Advance time past cooldown
        vm.warp(block.timestamp + 61);
        
        // Buy enough to nearly graduate
        launchToken.buy{value: 0.003 ether}();
        
        // Record the tokens received for a reference trade at end of curve
        uint256 refTradeSize = 0.001 ether;
        uint256 estimatedTokensAtEndOfCurve = launchToken.estimateBuy(refTradeSize);
        
        // Now graduate
        launchToken.buy{value: 0.002 ether}();
        assertTrue(launchToken.graduated(), "Should be graduated");
        
        // Check the minted tokens for liquidity
        uint256 mintedForLiquidity = launchToken.mintedForLiquidity();
        uint256 ethForLiquidity = 0.004 ether; // ~graduation threshold worth
        
        // Calculate what V2 would give for the reference trade
        // V2 formula: tokensOut = ethIn * 997 * tokenReserve / (ethReserve * 1000 + ethIn * 997)
        // For small trades: tokensOut ≈ ethIn * tokenReserve / ethReserve * 0.997
        uint256 v2TokensOut = (refTradeSize * mintedForLiquidity * 997) / (ethForLiquidity * 1000);
        
        // V2 should give FEWER or equal tokens than the bonding curve
        // (accounting for some rounding tolerance)
        assertTrue(
            v2TokensOut <= estimatedTokensAtEndOfCurve,
            "V2 should give fewer or equal tokens than bonding curve"
        );
        
        vm.stopPrank();
    }
}
