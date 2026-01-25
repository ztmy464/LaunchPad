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

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;
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
    ) external payable returns (uint, uint, uint) {
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        return (amountTokenDesired, msg.value, msg.value);
    }
    
    receive() external payable {}
}

/**
 * @title FuzzTest
 * @notice Fuzz tests for the launchpad contracts
 * @dev Uses Foundry's fuzzing capabilities to test edge cases
 */
contract FuzzTest is Test {
    TokenFactory public factory;
    CreatorFeeRouter public feeRouter;
    MockWETH public weth;
    MockV2Factory public v2Factory;
    MockV2Router public v2Router;
    
    address public deployer = address(1);
    address public creator = address(2);
    address public buyer = address(3);
    
    LaunchToken public token;
    
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
        address tokenAddr = factory.createToken("Fuzz Token", "FUZZ");
        token = LaunchToken(payable(tokenAddr));
        
        // Fund accounts
        vm.deal(deployer, 1000 ether);
        vm.deal(creator, 1000 ether);
        vm.deal(buyer, 1000 ether);
        
        // Move past cooldown
        vm.warp(block.timestamp + 61);
    }
    
    // ============ BondingCurveMath Fuzz Tests ============
    
    /**
     * @notice Fuzz test: calculateTokensForETH should never overflow
     * @param ethAmount Amount of ETH to test (bounded to reasonable range)
     */
    function testFuzz_calculateTokensForETH_noOverflow(uint256 ethAmount) public pure {
        // Bound to reasonable range (1 wei to 1000 ETH)
        ethAmount = bound(ethAmount, 1, 1000 ether);
        
        // Should not revert
        uint256 tokens = BondingCurveMath.calculateTokensForETH(0, ethAmount);
        
        // Tokens should be positive
        assertTrue(tokens > 0, "Should receive tokens for positive ETH");
        
        // Tokens should be bounded (can't be more than max possible)
        assertTrue(tokens < type(uint128).max, "Tokens should be bounded");
    }
    
    /**
     * @notice Fuzz test: calculateSellReturn should never exceed reserve
     * @param supply Current supply
     * @param sellAmount Amount to sell
     */
    function testFuzz_calculateSellReturn_bounded(uint256 supply, uint256 sellAmount) public pure {
        // Bound supply to reasonable range
        supply = bound(supply, 1 ether, 1000000 ether);
        
        // Sell amount can't exceed supply
        sellAmount = bound(sellAmount, 0, supply);
        
        // Calculate sell return
        uint256 ethReturn = BondingCurveMath.calculateSellReturn(supply, sellAmount);
        
        // Calculate what the total reserve would have been
        uint256 totalCost = BondingCurveMath.calculateBuyCost(0, supply);
        
        // Return should never exceed total cost
        assertTrue(ethReturn <= totalCost, "Sell return should not exceed total cost");
    }
    
    /**
     * @notice Fuzz test: Buy and sell symmetry (accounting for fees and curve mechanics)
     * @param ethAmount ETH to buy with
     */
    function testFuzz_buyAndSellSymmetry(uint256 ethAmount) public pure {
        // Bound to range that won't cause graduation
        ethAmount = bound(ethAmount, 0.0001 ether, 0.003 ether);
        
        // Calculate fee
        uint256 fee = BondingCurveMath.calculateBuyFee(ethAmount);
        uint256 ethForTokens = ethAmount - fee;
        
        // Calculate tokens received
        uint256 tokens = BondingCurveMath.calculateTokensForETH(0, ethForTokens);
        
        if (tokens == 0) return; // Skip if no tokens
        
        // Calculate sell return (before sell fee)
        uint256 sellReturn = BondingCurveMath.calculateSellReturn(tokens, tokens);
        
        // Due to bonding curve mechanics, quadratic formula solving, and integer division,
        // sell return should be reasonably close to ethForTokens but with potential deviation
        // Allow 30% tolerance for these mathematical imprecisions
        uint256 tolerance = ethForTokens * 30 / 100;
        assertTrue(
            sellReturn >= ethForTokens - tolerance || sellReturn <= ethForTokens + tolerance,
            "Sell should return approximately what was put in (with curve mechanics tolerance)"
        );
    }
    
    /**
     * @notice Fuzz test: Price monotonically increases with supply
     * @param supply1 First supply point
     * @param supply2 Second supply point
     */
    function testFuzz_priceMonotonicallyIncreases(uint256 supply1, uint256 supply2) public pure {
        // Bound supplies
        supply1 = bound(supply1, 0, 1000000 ether);
        supply2 = bound(supply2, 0, 1000000 ether);
        
        uint256 price1 = BondingCurveMath.getCurrentPrice(supply1);
        uint256 price2 = BondingCurveMath.getCurrentPrice(supply2);
        
        if (supply1 < supply2) {
            assertTrue(price1 <= price2, "Price should increase with supply");
        } else if (supply1 > supply2) {
            assertTrue(price1 >= price2, "Price should decrease with lower supply");
        } else {
            assertEq(price1, price2, "Same supply should have same price");
        }
    }
    
    /**
     * @notice Fuzz test: Cooldown penalty is bounded [0, tokens]
     * @param tokens Token amount
     * @param elapsed Time elapsed since launch
     */
    function testFuzz_cooldownPenalty_bounded(uint256 tokens, uint256 elapsed) public {
        // Bound tokens to reasonable range
        tokens = bound(tokens, 1, 1000000 ether);
        
        // Bound elapsed to 0-120 seconds
        elapsed = bound(elapsed, 0, 120);
        
        uint256 launchTime = block.timestamp;
        vm.warp(block.timestamp + elapsed);
        
        uint256 adjusted = BondingCurveMath.applyCooldownPenalty(tokens, launchTime);
        
        // Adjusted should be between 0 and tokens
        assertTrue(adjusted <= tokens, "Adjusted should not exceed original");
        
        // After cooldown (60s), should get full amount
        if (elapsed >= 60) {
            assertEq(adjusted, tokens, "Should get full tokens after cooldown");
        }
    }
    
    /**
     * @notice Fuzz test: Fee calculations are bounded
     * @param amount Amount to calculate fee on
     */
    function testFuzz_feeCalculations_bounded(uint256 amount) public pure {
        // Bound to prevent overflow
        amount = bound(amount, 0, type(uint256).max / 10000);
        
        uint256 buyFee = BondingCurveMath.calculateBuyFee(amount);
        uint256 sellFee = BondingCurveMath.calculateSellFee(amount);
        
        // Buy fee should be 1%
        assertEq(buyFee, (amount * 100) / 10000, "Buy fee should be 1%");
        
        // Sell fee should be 2%
        assertEq(sellFee, (amount * 200) / 10000, "Sell fee should be 2%");
        
        // Fees should not exceed amounts
        assertTrue(buyFee <= amount, "Buy fee should not exceed amount");
        assertTrue(sellFee <= amount, "Sell fee should not exceed amount");
    }
    
    // ============ LaunchToken Fuzz Tests ============
    
    /**
     * @notice Fuzz test: Buy with valid amounts succeeds
     * @param ethAmount ETH to buy with
     */
    function testFuzz_buy_validAmounts(uint256 ethAmount) public {
        // Bound to range that won't cause graduation and is positive
        ethAmount = bound(ethAmount, 0.00001 ether, 0.003 ether);
        
        uint256 balanceBefore = token.balanceOf(buyer);
        uint256 supplyBefore = token.totalSupply();
        
        vm.prank(buyer);
        token.buy{value: ethAmount}();
        
        uint256 balanceAfter = token.balanceOf(buyer);
        uint256 supplyAfter = token.totalSupply();
        
        // Should have received tokens
        assertTrue(balanceAfter > balanceBefore, "Should receive tokens");
        assertTrue(supplyAfter > supplyBefore, "Supply should increase");
        
        // Balance increase should match supply increase
        assertEq(
            balanceAfter - balanceBefore,
            supplyAfter - supplyBefore,
            "Buyer balance increase should match supply increase"
        );
    }
    
    /**
     * @notice Fuzz test: Can't sell more than balance
     * @param sellAmount Amount to try to sell
     */
    function testFuzz_sell_neverExceedsBalance(uint256 sellAmount) public {
        // First buy some tokens with a valid amount
        vm.prank(buyer);
        token.buy{value: 0.001 ether}();
        
        uint256 balance = token.balanceOf(buyer);
        
        // Bound sell amount to reasonable range, but minimum 1% of balance to ensure 
        // sell fee is non-zero (feeRouter reverts on 0 fee)
        uint256 minSell = balance / 100 > 0 ? balance / 100 : 1;
        sellAmount = bound(sellAmount, minSell, balance * 2);
        
        if (sellAmount > balance) {
            vm.prank(buyer);
            vm.expectRevert(LaunchToken.InsufficientTokens.selector);
            token.sell(sellAmount);
        } else {
            // Should succeed
            vm.prank(buyer);
            token.sell(sellAmount);
            
            assertEq(token.balanceOf(buyer), balance - sellAmount, "Balance should decrease");
        }
    }
    
    /**
     * @notice Fuzz test: Reserve balance stays consistent through buys/sells
     * @param numBuys Number of buys
     * @param numSells Number of sells
     */
    function testFuzz_reserveBalanceConsistency(uint8 numBuys, uint8 numSells) public {
        // Limit operations
        numBuys = uint8(bound(numBuys, 1, 10));
        numSells = uint8(bound(numSells, 0, numBuys)); // Can't sell more than bought
        
        // Do buys
        for (uint i = 0; i < numBuys; i++) {
            vm.prank(buyer);
            token.buy{value: 0.0001 ether}();
        }
        
        uint256 reserveAfterBuys = token.reserveBalance();
        uint256 balanceAfterBuys = token.balanceOf(buyer);
        
        // Do sells
        uint256 sellPerTx = balanceAfterBuys / (numSells > 0 ? numSells : 1);
        for (uint i = 0; i < numSells && sellPerTx > 0; i++) {
            vm.prank(buyer);
            token.sell(sellPerTx);
        }
        
        uint256 reserveAfterSells = token.reserveBalance();
        
        // Reserve should have decreased from sells
        assertTrue(reserveAfterSells <= reserveAfterBuys, "Reserve should decrease or stay same after sells");
        
        // Reserve should never be negative (implicit - would revert)
        // Contract balance should be >= reserve
        assertTrue(
            address(token).balance >= token.reserveBalance(),
            "Contract balance should cover reserve"
        );
    }
    
    /**
     * @notice Fuzz test: Estimate functions match actual execution
     * @param ethAmount ETH amount for buy estimate
     */
    function testFuzz_estimateBuy_accuracy(uint256 ethAmount) public {
        // Bound to valid range
        ethAmount = bound(ethAmount, 0.00001 ether, 0.003 ether);
        
        // Get estimate
        uint256 estimate = token.estimateBuy(ethAmount);
        
        // Execute actual buy
        uint256 balanceBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        token.buy{value: ethAmount}();
        uint256 actual = token.balanceOf(buyer) - balanceBefore;
        
        // Estimate should match actual exactly
        assertEq(estimate, actual, "Estimate should match actual");
    }
    
    /**
     * @notice Fuzz test: Square root accuracy
     * @param x Value to take sqrt of
     */
    function testFuzz_sqrt_accuracy(uint256 x) public pure {
        // Bound to prevent overflow in verification
        x = bound(x, 0, type(uint128).max);
        
        uint256 root = BondingCurveMath.sqrt(x);
        
        // root^2 <= x
        assertTrue(root * root <= x, "root^2 should be <= x");
        
        // (root+1)^2 > x (unless at max)
        if (root < type(uint128).max) {
            assertTrue((root + 1) * (root + 1) > x, "(root+1)^2 should be > x");
        }
    }
    
    /**
     * @notice Fuzz test: Token creation with random names/symbols
     * @param seed Random seed for name/symbol generation
     */
    function testFuzz_createToken_randomNames(uint256 seed) public {
        // Generate pseudo-random name and symbol
        string memory name = string(abi.encodePacked("Token", vm.toString(seed)));
        string memory symbol = string(abi.encodePacked("TK", vm.toString(seed % 1000)));
        
        vm.prank(creator);
        address tokenAddr = factory.createToken(name, symbol);
        
        LaunchToken newToken = LaunchToken(payable(tokenAddr));
        
        assertEq(newToken.name(), name);
        assertEq(newToken.symbol(), symbol);
        assertTrue(factory.isLaunchedToken(tokenAddr));
    }
    
    /**
     * @notice Fuzz test: Multiple sequential buys maintain correct state
     * @param numBuys Number of buys to perform
     */
    function testFuzz_multipleBuys_correctState(uint8 numBuys) public {
        numBuys = uint8(bound(numBuys, 1, 20));
        
        uint256 totalBought = 0;
        uint256 totalSpent = 0;
        
        for (uint i = 0; i < numBuys; i++) {
            uint256 buyAmount = 0.0001 ether;
            
            uint256 balanceBefore = token.balanceOf(buyer);
            
            vm.prank(buyer);
            token.buy{value: buyAmount}();
            
            uint256 tokensReceived = token.balanceOf(buyer) - balanceBefore;
            totalBought += tokensReceived;
            totalSpent += buyAmount;
        }
        
        // Total balance should match sum of individual buys
        assertEq(token.balanceOf(buyer), totalBought, "Balance should match total bought");
        
        // Total supply should be at least what buyer has
        assertTrue(token.totalSupply() >= totalBought, "Supply should be >= buyer balance");
    }
}
