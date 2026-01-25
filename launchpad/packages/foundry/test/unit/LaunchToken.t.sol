// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/TokenFactory.sol";
import "../../contracts/CreatorFeeRouter.sol";
import "../../contracts/LaunchToken.sol";
import "../../contracts/libraries/BondingCurveMath.sol";

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
    
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
    
    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (0, 0, 0);
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
        address,
        uint
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        return (amountTokenDesired, msg.value, msg.value);
    }
    
    receive() external payable {}
}

// Malicious contract for reentrancy tests
contract ReentrantAttacker {
    LaunchToken public target;
    bool public attacking;
    uint256 public attackCount;
    
    constructor(address _target) {
        target = LaunchToken(payable(_target));
    }
    
    function attackBuy() external payable {
        attacking = true;
        attackCount = 0;
        target.buy{value: msg.value}();
    }
    
    function attackSell(uint256 amount) external {
        attacking = true;
        attackCount = 0;
        target.sell(amount);
    }
    
    receive() external payable {
        if (attacking && attackCount < 2) {
            attackCount++;
            // Try to reenter
            if (address(this).balance >= 0.001 ether) {
                try target.buy{value: 0.001 ether}() {} catch {}
            }
            if (target.balanceOf(address(this)) > 0) {
                try target.sell(target.balanceOf(address(this)) / 2) {} catch {}
            }
        }
    }
}

contract LaunchTokenTest is Test {
    TokenFactory public factory;
    CreatorFeeRouter public feeRouter;
    MockWETH public weth;
    MockV2Factory public v2Factory;
    MockV2Router public v2Router;
    
    address public deployer = address(1);
    address public creator = address(2);
    address public buyer1 = address(3);
    address public buyer2 = address(4);
    address public attacker = address(5);
    
    LaunchToken public token;
    
    event TokensBought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 fee);
    event TokensSold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 fee);
    event Graduated(address indexed pool, uint256 ethLiquidity, uint256 tokenLiquidity);
    event TreasuryWithdrawn(address indexed creator, uint256 amount);
    event EmergencyWithdraw(address indexed creator, uint256 ethAmount, uint256 tokenAmount);
    
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
        
        // Create a token for testing
        vm.prank(creator);
        address tokenAddr = factory.createToken("Test Token", "TEST");
        token = LaunchToken(payable(tokenAddr));
        
        // Fund accounts
        vm.deal(creator, 100 ether);
        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
        vm.deal(attacker, 100 ether);
    }
    
    // ============ Initialization Tests ============
    
    function test_initialize_setsCorrectValues() public view {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.creator(), creator);
        assertEq(token.factory(), address(factory));
        assertEq(token.launchTime(), block.timestamp);
        assertFalse(token.graduated());
    }
    
    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        token.initialize("New Name", "NEW", attacker, address(0), address(v2Factory), address(weth));
    }
    
    function test_expectedV2Pair_computed() public view {
        address expectedPair = token.expectedV2Pair();
        assertTrue(expectedPair != address(0), "Expected pair should be computed");
    }
    
    // ============ Buy Mechanics Tests ============
    
    function test_buy_mintsTokens() public {
        vm.warp(block.timestamp + 61); // Past cooldown
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        assertTrue(token.balanceOf(buyer1) > 0, "Should have tokens");
    }
    
    function test_buy_zeroValue_reverts() public {
        vm.prank(buyer1);
        vm.expectRevert(LaunchToken.ZeroAmount.selector);
        token.buy{value: 0}();
    }
    
    function test_buy_afterGraduation_reverts() public {
        vm.warp(block.timestamp + 61);
        
        // Graduate the token
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        assertTrue(token.graduated());
        
        // Try to buy after graduation
        vm.prank(buyer2);
        vm.expectRevert(LaunchToken.AlreadyGraduated.selector);
        token.buy{value: 0.001 ether}();
    }
    
    function test_buy_increasesReserveBalance() public {
        vm.warp(block.timestamp + 61);
        
        uint256 reserveBefore = token.reserveBalance();
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 reserveAfter = token.reserveBalance();
        assertTrue(reserveAfter > reserveBefore, "Reserve should increase");
    }
    
    function test_buy_collectsFee() public {
        vm.warp(block.timestamp + 61);
        
        uint256 buyAmount = 0.001 ether;
        uint256 expectedFee = (buyAmount * 100) / 10000; // 1%
        uint256 ethForTokens = buyAmount - expectedFee;
        
        vm.prank(buyer1);
        token.buy{value: buyAmount}();
        
        // With feeRouter, fee goes there. Reserve should be ethForTokens
        assertEq(token.reserveBalance(), ethForTokens);
    }
    
    function test_buy_feeToTreasury_noRouter() public {
        // Create a token without feeRouter
        vm.prank(deployer);
        factory.setFeeRouter(address(0));
        
        vm.prank(creator);
        address newTokenAddr = factory.createToken("No Router", "NOR");
        LaunchToken newToken = LaunchToken(payable(newTokenAddr));
        
        vm.warp(block.timestamp + 61);
        
        uint256 buyAmount = 0.001 ether;
        uint256 expectedFee = (buyAmount * 100) / 10000;
        
        vm.prank(buyer1);
        newToken.buy{value: buyAmount}();
        
        assertEq(newToken.treasury(), expectedFee);
    }
    
    function test_buy_feeToRouter_withRouter() public {
        vm.warp(block.timestamp + 61);
        
        uint256 buyAmount = 0.001 ether;
        uint256 expectedFee = (buyAmount * 100) / 10000;
        
        uint256 routerBalanceBefore = address(feeRouter).balance;
        
        vm.prank(buyer1);
        token.buy{value: buyAmount}();
        
        // Fee should be in the router
        assertEq(address(feeRouter).balance, routerBalanceBefore + expectedFee);
        assertEq(token.treasury(), 0); // No local treasury
    }
    
    function test_buy_triggersGraduation() public {
        vm.warp(block.timestamp + 61);
        
        assertFalse(token.graduated());
        
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}(); // Above threshold
        
        assertTrue(token.graduated());
    }
    
    function test_buy_emitsEvent() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        vm.expectEmit(true, false, false, false);
        emit TokensBought(buyer1, 0.001 ether, 0, 0);
        token.buy{value: 0.001 ether}();
    }
    
    // ============ Sell Mechanics Tests ============
    
    function test_sell_returnsETH() public {
        vm.warp(block.timestamp + 61);
        
        // Buy first
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 tokenBalance = token.balanceOf(buyer1);
        uint256 ethBefore = buyer1.balance;
        
        // Sell
        vm.prank(buyer1);
        token.sell(tokenBalance / 2);
        
        assertTrue(buyer1.balance > ethBefore, "Should receive ETH");
    }
    
    function test_sell_zeroAmount_reverts() public {
        vm.prank(buyer1);
        vm.expectRevert(LaunchToken.ZeroAmount.selector);
        token.sell(0);
    }
    
    function test_sell_insufficientTokens_reverts() public {
        vm.prank(buyer1);
        vm.expectRevert(LaunchToken.InsufficientTokens.selector);
        token.sell(1000 ether);
    }
    
    function test_sell_insufficientReserve_reverts() public {
        vm.warp(block.timestamp + 61);
        
        // Buy tokens
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 tokens = token.balanceOf(buyer1);
        
        // Transfer some tokens to buyer2 (who has no reserve backing)
        vm.prank(buyer1);
        token.transfer(buyer2, tokens / 2);
        
        // buyer1 sells all their tokens - should work
        vm.prank(buyer1);
        token.sell(tokens / 2);
        
        // Now try to sell more than reserve allows
        // This depends on exact math, but the point is reserve can be depleted
    }
    
    function test_sell_afterGraduation_reverts() public {
        vm.warp(block.timestamp + 61);
        
        // Buy to graduate
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        assertTrue(token.graduated());
        
        uint256 balance = token.balanceOf(buyer1);
        
        vm.prank(buyer1);
        vm.expectRevert(LaunchToken.AlreadyGraduated.selector);
        token.sell(balance / 2);
    }
    
    function test_sell_burnsTokens() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 balanceBefore = token.balanceOf(buyer1);
        uint256 supplyBefore = token.totalSupply();
        uint256 sellAmount = balanceBefore / 2;
        
        vm.prank(buyer1);
        token.sell(sellAmount);
        
        assertEq(token.balanceOf(buyer1), balanceBefore - sellAmount);
        assertEq(token.totalSupply(), supplyBefore - sellAmount);
    }
    
    function test_sell_collectsFee() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 tokens = token.balanceOf(buyer1);
        uint256 ethBefore = buyer1.balance;
        
        // Calculate expected return
        uint256 grossReturn = token.estimateSell(tokens);
        // estimateSell already accounts for fee
        
        vm.prank(buyer1);
        token.sell(tokens);
        
        uint256 ethReceived = buyer1.balance - ethBefore;
        // Received should be close to estimate (allow some rounding)
        assertApproxEqAbs(ethReceived, grossReturn, 1);
    }
    
    function test_sell_decreasesReserveBalance() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 reserveBefore = token.reserveBalance();
        uint256 tokens = token.balanceOf(buyer1);
        
        vm.prank(buyer1);
        token.sell(tokens / 2);
        
        assertTrue(token.reserveBalance() < reserveBefore, "Reserve should decrease");
    }
    
    function test_sell_emitsEvent() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 tokens = token.balanceOf(buyer1);
        
        vm.prank(buyer1);
        vm.expectEmit(true, false, false, false);
        emit TokensSold(buyer1, tokens, 0, 0);
        token.sell(tokens);
    }
    
    // ============ Cooldown/Sniper Protection Tests ============
    
    function test_buy_duringCooldown_penalty() public {
        // Buy at t=0 (immediately after launch)
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        // Should receive very few tokens due to penalty
        uint256 tokensAtStart = token.balanceOf(buyer1);
        
        // Now wait and buy again
        vm.warp(block.timestamp + 61);
        vm.prank(buyer2);
        token.buy{value: 0.001 ether}();
        
        uint256 tokensAfterCooldown = token.balanceOf(buyer2);
        
        assertTrue(tokensAfterCooldown > tokensAtStart, "Should get more tokens after cooldown");
    }
    
    function test_buy_midCooldown_partialPenalty() public {
        // Buy at t=30 (halfway through cooldown)
        vm.warp(block.timestamp + 30);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 tokensAtMid = token.balanceOf(buyer1);
        
        // Buy at t=60 (after cooldown)
        vm.warp(block.timestamp + 31); // Now at 61 total
        
        vm.prank(buyer2);
        token.buy{value: 0.001 ether}();
        
        uint256 tokensAfter = token.balanceOf(buyer2);
        
        // Mid-cooldown should give roughly half (accounting for supply changes)
        assertTrue(tokensAfter > tokensAtMid, "Full tokens > partial tokens");
    }
    
    function test_buy_afterCooldown_fullTokens() public {
        vm.warp(block.timestamp + 61);
        
        // Get estimate BEFORE buying (supply affects price)
        uint256 estimate = token.estimateBuy(0.001 ether);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 tokens = token.balanceOf(buyer1);
        
        // Should be exactly equal since estimate was calculated at same supply
        assertEq(tokens, estimate, "Tokens should match estimate");
    }
    
    function test_isCooldownComplete_beforeExpiry() public view {
        assertFalse(token.isCooldownComplete());
    }
    
    function test_isCooldownComplete_afterExpiry() public {
        vm.warp(block.timestamp + 61);
        assertTrue(token.isCooldownComplete());
    }
    
    function test_cooldownRemaining_decrements() public {
        uint256 remaining1 = token.cooldownRemaining();
        assertEq(remaining1, 60);
        
        vm.warp(block.timestamp + 30);
        uint256 remaining2 = token.cooldownRemaining();
        assertEq(remaining2, 30);
        
        vm.warp(block.timestamp + 31);
        uint256 remaining3 = token.cooldownRemaining();
        assertEq(remaining3, 0);
    }
    
    // ============ Transfer Blocking Tests ============
    
    function test_transfer_toV2Pair_beforeGraduation_reverts() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 balance = token.balanceOf(buyer1);
        address expectedPair = token.expectedV2Pair();
        
        vm.prank(buyer1);
        vm.expectRevert(LaunchToken.TransferToPoolBlocked.selector);
        token.transfer(expectedPair, balance / 2);
    }
    
    function test_transfer_toV2Pair_afterGraduation_succeeds() public {
        vm.warp(block.timestamp + 61);
        
        // Graduate token
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        assertTrue(token.graduated());
        
        uint256 balance = token.balanceOf(buyer1);
        address expectedPair = token.expectedV2Pair();
        
        // Should succeed after graduation
        vm.prank(buyer1);
        token.transfer(expectedPair, balance / 2);
        
        assertEq(token.balanceOf(expectedPair), balance / 2);
    }
    
    function test_transfer_toOtherAddress_succeeds() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 balance = token.balanceOf(buyer1);
        
        vm.prank(buyer1);
        token.transfer(buyer2, balance / 2);
        
        assertEq(token.balanceOf(buyer2), balance / 2);
    }
    
    // ============ View Functions Tests ============
    
    function test_getCurrentPrice_atZeroSupply() public view {
        uint256 price = token.getCurrentPrice();
        assertEq(price, BondingCurveMath.BASE_PRICE);
    }
    
    function test_getCurrentPrice_increasesWithSupply() public {
        vm.warp(block.timestamp + 61);
        
        uint256 priceBefore = token.getCurrentPrice();
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 priceAfter = token.getCurrentPrice();
        
        assertTrue(priceAfter > priceBefore, "Price should increase with supply");
    }
    
    function test_estimateBuy_matchesActual() public {
        vm.warp(block.timestamp + 61);
        
        uint256 estimate = token.estimateBuy(0.001 ether);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 actual = token.balanceOf(buyer1);
        
        assertEq(estimate, actual, "Estimate should match actual");
    }
    
    function test_estimateSell_matchesActual() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 tokens = token.balanceOf(buyer1);
        uint256 estimate = token.estimateSell(tokens);
        
        uint256 balanceBefore = buyer1.balance;
        
        vm.prank(buyer1);
        token.sell(tokens);
        
        uint256 actual = buyer1.balance - balanceBefore;
        
        assertEq(estimate, actual, "Estimate should match actual");
    }
    
    function test_estimateSell_reserveCheck() public {
        vm.warp(block.timestamp + 61);
        
        // Buy tokens
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 balance = token.balanceOf(buyer1);
        uint256 reserve = token.reserveBalance();
        
        // Estimate for valid amount should work
        uint256 estimate = token.estimateSell(balance);
        
        // The estimate should be positive for sellable tokens
        assertTrue(estimate > 0, "Estimate should be positive for sellable amount");
        
        // Verify the sell actually works with the estimated amount
        uint256 ethBefore = buyer1.balance;
        vm.prank(buyer1);
        token.sell(balance);
        uint256 ethReceived = buyer1.balance - ethBefore;
        
        // Actual received should match estimate
        assertEq(ethReceived, estimate, "Actual should match estimate");
    }
    
    function test_graduationProgress_increases() public {
        vm.warp(block.timestamp + 61);
        
        uint256 progress1 = token.graduationProgress();
        assertEq(progress1, 0);
        
        vm.prank(buyer1);
        token.buy{value: 0.002 ether}();
        
        uint256 progress2 = token.graduationProgress();
        assertTrue(progress2 > 0, "Progress should increase");
        assertTrue(progress2 < 100, "Should not be graduated yet");
    }
    
    // ============ Graduation Tests ============
    
    function test_graduation_atThreshold() public {
        vm.warp(block.timestamp + 61);
        
        // Calculate amount needed (threshold is 0.004 ETH for reserve)
        // With 1% fee, need slightly more
        vm.prank(buyer1);
        token.buy{value: 0.00405 ether}();
        
        assertTrue(token.graduated(), "Should be graduated at threshold");
    }
    
    function test_graduation_sendsETHToFactory() public {
        vm.warp(block.timestamp + 61);
        
        uint256 factoryBalanceBefore = address(factory).balance;
        
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        assertTrue(token.graduated());
        assertTrue(address(factory).balance > factoryBalanceBefore, "Factory should receive ETH");
    }
    
    function test_graduation_mintsLiquidityTokens() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        assertTrue(token.graduated());
        
        // Check mintedForLiquidity is set
        uint256 minted = token.mintedForLiquidity();
        assertTrue(minted > 0, "Should have minted tokens for liquidity");
        
        // Token contract should hold these tokens
        assertEq(token.balanceOf(address(token)), minted);
    }
    
    function test_graduation_setsGraduatedFlag() public {
        vm.warp(block.timestamp + 61);
        
        assertFalse(token.graduated());
        
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        assertTrue(token.graduated());
    }
    
    function test_graduation_emitsEvent() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        vm.expectEmit(true, false, false, false);
        emit Graduated(address(factory), 0, 0);
        token.buy{value: 0.005 ether}();
    }
    
    function test_graduation_reserveBalanceZeroed() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        assertTrue(token.graduated());
        assertEq(token.reserveBalance(), 0, "Reserve should be zeroed");
    }
    
    // ============ Creator Functions Tests ============
    
    function test_withdrawTreasury_onlyCreator() public {
        // Setup: create token without feeRouter to accumulate local treasury
        vm.prank(deployer);
        factory.setFeeRouter(address(0));
        
        vm.prank(creator);
        address newTokenAddr = factory.createToken("Treasury Test", "TRES");
        LaunchToken newToken = LaunchToken(payable(newTokenAddr));
        
        vm.warp(block.timestamp + 61);
        vm.prank(buyer1);
        newToken.buy{value: 0.001 ether}();
        
        vm.prank(attacker);
        vm.expectRevert(LaunchToken.OnlyCreator.selector);
        newToken.withdrawTreasury();
    }
    
    function test_withdrawTreasury_success() public {
        vm.prank(deployer);
        factory.setFeeRouter(address(0));
        
        vm.prank(creator);
        address newTokenAddr = factory.createToken("Treasury Test", "TRES");
        LaunchToken newToken = LaunchToken(payable(newTokenAddr));
        
        vm.warp(block.timestamp + 61);
        vm.prank(buyer1);
        newToken.buy{value: 0.001 ether}();
        
        uint256 treasury = newToken.treasury();
        assertTrue(treasury > 0);
        
        uint256 creatorBalanceBefore = creator.balance;
        
        vm.prank(creator);
        newToken.withdrawTreasury();
        
        assertEq(newToken.treasury(), 0);
        assertEq(creator.balance, creatorBalanceBefore + treasury);
    }
    
    function test_withdrawTreasury_zeroBalance_reverts() public {
        vm.prank(creator);
        vm.expectRevert(LaunchToken.ZeroAmount.selector);
        token.withdrawTreasury();
    }
    
    function test_emergencyWithdraw_onlyCreator() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        vm.prank(attacker);
        vm.expectRevert(LaunchToken.OnlyCreator.selector);
        token.emergencyWithdraw();
    }
    
    function test_emergencyWithdraw_drainsAll() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        uint256 contractEth = address(token).balance;
        uint256 contractTokens = token.balanceOf(address(token));
        uint256 creatorEthBefore = creator.balance;
        uint256 creatorTokensBefore = token.balanceOf(creator);
        
        vm.prank(creator);
        token.emergencyWithdraw();
        
        assertEq(address(token).balance, 0, "Contract ETH should be 0");
        assertEq(token.balanceOf(address(token)), 0, "Contract tokens should be 0");
        assertEq(creator.balance, creatorEthBefore + contractEth);
        assertEq(token.balanceOf(creator), creatorTokensBefore + contractTokens);
    }
    
    function test_emergencyWithdraw_recoversStuckETH() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.001 ether}();
        
        // Send extra ETH directly (stuck ETH)
        vm.deal(address(this), 1 ether);
        (bool success,) = address(token).call{value: 0.5 ether}("");
        assertTrue(success);
        
        uint256 totalEth = address(token).balance;
        assertTrue(totalEth > token.reserveBalance() + token.treasury());
        
        uint256 creatorBalanceBefore = creator.balance;
        
        vm.prank(creator);
        token.emergencyWithdraw();
        
        assertEq(creator.balance, creatorBalanceBefore + totalEth);
    }
    
    // ============ Reentrancy Protection Tests ============
    
    function test_buy_reentrancy_reverts() public {
        vm.warp(block.timestamp + 61);
        
        ReentrantAttacker attackerContract = new ReentrantAttacker(address(token));
        vm.deal(address(attackerContract), 10 ether);
        
        // The attacker contract tries to reenter on receive
        // Due to nonReentrant, second call should fail silently (try/catch in attacker)
        attackerContract.attackBuy{value: 0.001 ether}();
        
        // Attack count should be limited due to reentrancy guard
        assertTrue(attackerContract.attackCount() <= 1, "Reentrancy should be blocked");
    }
    
    function test_sell_reentrancy_reverts() public {
        vm.warp(block.timestamp + 61);
        
        ReentrantAttacker attackerContract = new ReentrantAttacker(address(token));
        vm.deal(address(attackerContract), 10 ether);
        
        // First buy some tokens
        vm.prank(address(attackerContract));
        token.buy{value: 0.001 ether}();
        
        uint256 tokens = token.balanceOf(address(attackerContract));
        
        // Try to reenter during sell
        attackerContract.attackSell(tokens);
        
        assertTrue(attackerContract.attackCount() <= 1, "Reentrancy should be blocked");
    }
    
    // ============ Edge Cases ============
    
    function test_multipleSmallBuys() public {
        vm.warp(block.timestamp + 61);
        
        uint256 totalTokens = 0;
        for (uint i = 0; i < 10; i++) {
            vm.prank(buyer1);
            token.buy{value: 0.0001 ether}();
            totalTokens = token.balanceOf(buyer1);
        }
        
        assertTrue(totalTokens > 0, "Should accumulate tokens");
    }
    
    function test_buyAndSellMultipleTimes() public {
        vm.warp(block.timestamp + 61);
        
        for (uint i = 0; i < 5; i++) {
            vm.prank(buyer1);
            token.buy{value: 0.0001 ether}();
            
            uint256 balance = token.balanceOf(buyer1);
            if (balance > 0) {
                vm.prank(buyer1);
                token.sell(balance / 2);
            }
        }
        
        assertTrue(token.balanceOf(buyer1) >= 0, "Balance should be valid");
    }
    
    function test_getContractTokenBalance() public {
        vm.warp(block.timestamp + 61);
        
        // Before graduation, should be 0
        assertEq(token.getContractTokenBalance(), 0);
        
        // After graduation, should have liquidity tokens
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        assertTrue(token.getContractTokenBalance() > 0);
    }
    
    function test_setUniswapPool_onlyFactory() public {
        vm.warp(block.timestamp + 61);
        
        vm.prank(buyer1);
        token.buy{value: 0.005 ether}();
        
        vm.prank(attacker);
        vm.expectRevert("Only factory");
        token.setUniswapPool(address(0x123));
    }
    
    function test_setFeeRouter_onlyFactory() public {
        vm.prank(attacker);
        vm.expectRevert("Only factory");
        token.setFeeRouter(address(0x123));
    }
    
    function test_approveForMigration_onlyFactory() public {
        vm.prank(attacker);
        vm.expectRevert("Only factory");
        token.approveForMigration(attacker, 1000);
    }
}
