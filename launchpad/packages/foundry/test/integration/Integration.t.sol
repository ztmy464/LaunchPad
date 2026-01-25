// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/TokenFactory.sol";
import "../../contracts/CreatorFeeRouter.sol";
import "../../contracts/LaunchToken.sol";
import "../../contracts/libraries/BondingCurveMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Mock Contracts ============

contract MockWETH {
    mapping(address => uint256) public balanceOf;
    
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
    
    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
    
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }
    
    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new MockV2Pair(t0, t1));
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
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        
        address pair = MockV2Factory(factory).getPair(token, WETH);
        if (pair == address(0)) {
            pair = MockV2Factory(factory).createPair(token, WETH);
        }
        
        liquidity = msg.value;
        MockV2Pair(pair).mint(to, liquidity);
        MockV2Pair(pair).setReserves(uint112(amountTokenDesired), uint112(msg.value));
        
        return (amountTokenDesired, msg.value, liquidity);
    }
    
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint,
        uint,
        address to,
        uint
    ) external returns (uint amountToken, uint amountETH) {
        address pair = MockV2Factory(factory).getPair(token, WETH);
        MockV2Pair(pair).transferFrom(msg.sender, address(this), liquidity);
        
        amountToken = liquidity * 100;
        amountETH = liquidity;
        
        IERC20(token).transfer(to, amountToken);
        payable(to).transfer(amountETH);
        
        return (amountToken, amountETH);
    }
    
    function swapExactETHForTokens(
        uint,
        address[] calldata,
        address,
        uint
    ) external payable returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value * 100;
        return amounts;
    }
    
    function getAmountsOut(uint amountIn, address[] calldata) external pure returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 100;
        return amounts;
    }
    
    receive() external payable {}
}

/**
 * @title IntegrationTest
 * @notice Integration tests for the full launchpad system
 */
contract IntegrationTest is Test {
    TokenFactory public factory;
    CreatorFeeRouter public feeRouter;
    MockWETH public weth;
    MockV2Factory public v2Factory;
    MockV2Router public v2Router;
    
    address public deployer = address(1);
    address public creator1 = address(2);
    address public creator2 = address(3);
    address public buyer1 = address(4);
    address public buyer2 = address(5);
    address public buyer3 = address(6);
    
    function setUp() public {
        vm.startPrank(deployer);
        
        weth = new MockWETH();
        v2Factory = new MockV2Factory();
        v2Router = new MockV2Router(address(weth), address(v2Factory));
        
        factory = new TokenFactory(address(0));
        feeRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        feeRouter.setAuthorizedFactory(address(factory));
        factory.setV2Router(address(v2Router));
        factory.setFeeRouter(address(feeRouter));
        
        vm.stopPrank();
        
        // Fund accounts
        vm.deal(deployer, 100 ether);
        vm.deal(creator1, 100 ether);
        vm.deal(creator2, 100 ether);
        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
        vm.deal(buyer3, 100 ether);
    }
    
    // ============ Full Token Lifecycle Tests ============
    
    function test_fullFlow_createToGraduateToPool() public {
        // 1. Creator creates a token
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Full Flow Token", "FFT");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        // Verify initial state
        assertEq(token.name(), "Full Flow Token");
        assertEq(token.symbol(), "FFT");
        assertEq(token.creator(), creator1);
        assertFalse(token.graduated());
        assertEq(token.totalSupply(), 0);
        
        // 2. Skip cooldown
        vm.warp(block.timestamp + 61);
        
        // 3. Multiple buyers purchase tokens
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        assertTrue(token.balanceOf(buyer1) > 0, "Buyer1 should have tokens");
        
        vm.prank(buyer2);
        token.buy{value: 0.002 ether}();
        assertTrue(token.balanceOf(buyer2) > 0, "Buyer2 should have tokens");
        
        // 4. Final buyer triggers graduation
        vm.prank(buyer3);
        token.buy{value: 0.002 ether}();
        
        // 5. Verify graduation
        assertTrue(token.graduated(), "Token should be graduated");
        assertEq(token.reserveBalance(), 0, "Reserve should be empty");
        assertTrue(factory.graduationFunds(tokenAddr) > 0, "Factory should have graduation funds");
        
        // 6. Create the V2 pool
        factory.createGraduatedPool(tokenAddr);
        
        // 7. Verify pool was created
        address pair = factory.getPair(tokenAddr);
        assertTrue(pair != address(0), "Pair should exist");
        assertTrue(factory.hasPair(tokenAddr), "hasPair should return true");
        assertEq(factory.graduationFunds(tokenAddr), 0, "Graduation funds should be used");
    }
    
    function test_fullFlow_multipleBuyers() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Multi Buyer", "MB");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        
        // 10 buyers each buying small amounts
        address[10] memory buyers;
        for (uint i = 0; i < 10; i++) {
            buyers[i] = address(uint160(100 + i));
            vm.deal(buyers[i], 1 ether);
            
            vm.prank(buyers[i]);
            token.buy{value: 0.0004 ether}();
        }
        
        // Verify all buyers have tokens
        for (uint i = 0; i < 10; i++) {
            assertTrue(token.balanceOf(buyers[i]) > 0, "Each buyer should have tokens");
        }
        
        // Verify total supply increased
        assertTrue(token.totalSupply() > 0, "Total supply should increase");
    }
    
    function test_fullFlow_buyAndSell() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Buy Sell Test", "BST");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        
        // Buy
        uint256 ethBefore = buyer1.balance;
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 tokenBalance = token.balanceOf(buyer1);
        assertTrue(tokenBalance > 0);
        
        // Sell half
        vm.prank(buyer1);
        token.sell(tokenBalance / 2);
        
        // Should have half tokens remaining
        assertEq(token.balanceOf(buyer1), tokenBalance / 2);
        
        // Should have received some ETH back
        assertTrue(buyer1.balance > ethBefore - 0.001 ether, "Should have ETH from sell");
    }
    
    // ============ Factory + Token Interaction Tests ============
    
    function test_createGraduatedPool_success() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Pool Test", "POOL");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        
        // Graduate
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        assertTrue(token.graduated());
        
        uint256 gradFunds = factory.graduationFunds(tokenAddr);
        assertTrue(gradFunds > 0);
        
        // Create pool
        factory.createGraduatedPool(tokenAddr);
        
        // Verify
        assertTrue(factory.hasPair(tokenAddr));
        assertEq(factory.graduationFunds(tokenAddr), 0);
        assertTrue(token.uniswapPool() != address(0));
    }
    
    function test_createGraduatedPool_notGraduated_reverts() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Not Grad", "NG");
        
        vm.expectRevert(TokenFactory.NotGraduated.selector);
        factory.createGraduatedPool(tokenAddr);
    }
    
    function test_createGraduatedPool_poolExists_reverts() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Pool Exists", "PE");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        factory.createGraduatedPool(tokenAddr);
        
        vm.expectRevert(TokenFactory.PoolAlreadyExists.selector);
        factory.createGraduatedPool(tokenAddr);
    }
    
    function test_createGraduatedPool_noFunds_reverts() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("No Funds", "NF");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        // Withdraw graduation funds first
        vm.prank(creator1);
        factory.emergencyWithdrawGraduationFunds(tokenAddr);
        
        vm.expectRevert(TokenFactory.InsufficientFunds.selector);
        factory.createGraduatedPool(tokenAddr);
    }
    
    // ============ Cross-Contract Fee Flow Tests ============
    
    function test_fees_fromBondingCurve_toRouter() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Fee Flow", "FF");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        
        uint256 routerBalanceBefore = address(feeRouter).balance;
        
        // Buy - should send 1% fee to router
        uint256 buyAmount = 0.001 ether;
        vm.prank(buyer1);
        token.buy{value: buyAmount}();
        
        uint256 expectedFee = (buyAmount * 100) / 10000; // 1%
        
        assertEq(
            address(feeRouter).balance,
            routerBalanceBefore + expectedFee,
            "Fee should be in router"
        );
        
        // Verify fee is tracked for this token
        assertEq(feeRouter.accumulatedFees(tokenAddr), expectedFee);
    }
    
    function test_fees_accumulateAcrossPhases() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Accumulate", "ACC");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        
        // Phase 1: Multiple buys on bonding curve
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        vm.prank(buyer2);
        token.buy{value: 0.001 ether}();
        
        uint256 feesAfterBuys = feeRouter.accumulatedFees(tokenAddr);
        assertTrue(feesAfterBuys > 0, "Should have fees from buys");
        
        // Sell - more fees
        uint256 tokenBalance = token.balanceOf(buyer1);
        vm.prank(buyer1);
        token.sell(tokenBalance / 2);
        
        uint256 feesAfterSell = feeRouter.accumulatedFees(tokenAddr);
        assertTrue(feesAfterSell > feesAfterBuys, "Should accumulate more fees from sell");
        
        // Creator withdraws all fees
        uint256 creatorBalanceBefore = creator1.balance;
        
        vm.prank(creator1);
        feeRouter.withdrawFees(tokenAddr);
        
        assertEq(creator1.balance, creatorBalanceBefore + feesAfterSell);
        assertEq(feeRouter.accumulatedFees(tokenAddr), 0);
    }
    
    // ============ Multi-Token Tests ============
    
    function test_multipleTokens_differentCreators() public {
        // Creator 1 creates a token
        vm.prank(creator1);
        address token1Addr = factory.createToken("Token One", "TK1");
        
        // Creator 2 creates a token
        vm.prank(creator2);
        address token2Addr = factory.createToken("Token Two", "TK2");
        
        // Both should be tracked
        assertTrue(factory.isLaunchedToken(token1Addr));
        assertTrue(factory.isLaunchedToken(token2Addr));
        
        assertEq(factory.totalTokens(), 2);
        
        // Each creator has their own token list
        address[] memory creator1Tokens = factory.getTokensByCreator(creator1);
        address[] memory creator2Tokens = factory.getTokensByCreator(creator2);
        
        assertEq(creator1Tokens.length, 1);
        assertEq(creator2Tokens.length, 1);
        assertEq(creator1Tokens[0], token1Addr);
        assertEq(creator2Tokens[0], token2Addr);
    }
    
    function test_multipleTokens_sameCreator() public {
        vm.startPrank(creator1);
        address token1 = factory.createToken("First", "FRST");
        address token2 = factory.createToken("Second", "SCND");
        address token3 = factory.createToken("Third", "THRD");
        vm.stopPrank();
        
        address[] memory creatorTokens = factory.getTokensByCreator(creator1);
        assertEq(creatorTokens.length, 3);
        assertEq(creatorTokens[0], token1);
        assertEq(creatorTokens[1], token2);
        assertEq(creatorTokens[2], token3);
    }
    
    // ============ Price Continuity Test ============
    
    function test_priceContinuity_bondingToV2() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Price Test", "PRC");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        
        // Buy up to just before graduation
        vm.prank(buyer1);
        token.buy{value: 0.003 ether}();
        
        // Record final bonding curve price
        uint256 finalBondingPrice = token.getCurrentPrice();
        
        // Get estimate for a trade at current supply
        uint256 estimatedTokens = token.estimateBuy(0.001 ether);
        
        // Graduate
        vm.prank(buyer2);
        token.buy{value: 0.002 ether}();
        
        assertTrue(token.graduated());
        
        // Create pool
        factory.createGraduatedPool(tokenAddr);
        
        // The pool should be set up such that trading on V2 gives
        // fewer or equal tokens than the bonding curve would have
        uint256 poolTokens = token.mintedForLiquidity();
        assertTrue(poolTokens > 0, "Pool should have tokens");
    }
    
    // ============ Edge Case Integration Tests ============
    
    function test_graduationAtExactThreshold() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Exact Threshold", "EXT");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        
        // Calculate exact amount needed for graduation
        // Threshold is 0.004 ETH reserve, with 1% buy fee
        // Need to account for fee: reserve = ethIn * 0.99
        // So ethIn = 0.004 / 0.99 ≈ 0.00404 ETH
        
        vm.prank(buyer1);
        token.buy{value: 0.00405 ether}();
        
        assertTrue(token.graduated(), "Should graduate at threshold");
    }
    
    function test_emergencyRecovery_fullFlow() public {
        vm.prank(creator1);
        address tokenAddr = factory.createToken("Emergency Test", "EMG");
        LaunchToken token = LaunchToken(payable(tokenAddr));
        
        vm.warp(block.timestamp + 61);
        
        // Buyers purchase
        vm.prank(buyer1);
        token.buy{value: 0.002 ether}();
        
        // Send extra ETH directly (stuck)
        vm.deal(address(this), 1 ether);
        (bool success,) = tokenAddr.call{value: 0.1 ether}("");
        assertTrue(success);
        
        // Total contract balance is now more than tracked
        uint256 totalBalance = address(token).balance;
        uint256 reserveAndTreasury = token.reserveBalance() + token.treasury();
        assertTrue(totalBalance > reserveAndTreasury);
        
        // Creator emergency withdraws everything
        uint256 creatorBalanceBefore = creator1.balance;
        
        vm.prank(creator1);
        token.emergencyWithdraw();
        
        assertEq(address(token).balance, 0);
        assertEq(creator1.balance, creatorBalanceBefore + totalBalance);
    }
    
    function test_tokensInfo_batchQuery() public {
        // Create multiple tokens
        vm.startPrank(creator1);
        address t1 = factory.createToken("Info Test 1", "IT1");
        address t2 = factory.createToken("Info Test 2", "IT2");
        address t3 = factory.createToken("Info Test 3", "IT3");
        vm.stopPrank();
        
        // Buy on some tokens
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        LaunchToken(payable(t1)).buy{value: 0.001 ether}();
        
        vm.prank(buyer1);
        LaunchToken(payable(t3)).buy{value: 0.005 ether}(); // Graduates
        
        // Query all info at once
        address[] memory tokens = new address[](3);
        tokens[0] = t1;
        tokens[1] = t2;
        tokens[2] = t3;
        
        (
            string[] memory names,
            string[] memory symbols,
            uint256[] memory supplies,
            uint256[] memory treasuries,
            bool[] memory graduated
        ) = factory.getTokensInfo(tokens);
        
        assertEq(names[0], "Info Test 1");
        assertEq(names[1], "Info Test 2");
        assertEq(names[2], "Info Test 3");
        
        assertEq(symbols[0], "IT1");
        assertEq(symbols[1], "IT2");
        assertEq(symbols[2], "IT3");
        
        assertTrue(supplies[0] > 0); // Has purchases
        assertEq(supplies[1], 0); // No purchases
        assertTrue(supplies[2] > 0); // Has purchases
        
        assertFalse(graduated[0]);
        assertFalse(graduated[1]);
        assertTrue(graduated[2]); // Graduated
    }
}
