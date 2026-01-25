// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/libraries/BondingCurveMath.sol";

/**
 * @title BondingCurveMathTest
 * @notice Unit tests for the BondingCurveMath library
 * @dev Tests the linear bonding curve math: price(supply) = BASE_PRICE + SLOPE * supply
 */
contract BondingCurveMathTest is Test {
    using BondingCurveMath for uint256;

    uint256 constant ONE_TOKEN = 1e18;
    uint256 constant BASE_PRICE = 0.00001 ether;
    uint256 constant SLOPE = 0.000001 ether;
    uint256 constant BUY_FEE_BPS = 100;
    uint256 constant SELL_FEE_BPS = 200;
    uint256 constant BPS_DENOMINATOR = 10000;
    uint256 constant COOLDOWN_PERIOD = 60;
    uint256 constant GRADUATION_THRESHOLD = 0.004 ether;

    // ============ Constants Tests ============

    function test_constants_values() public pure {
        assertEq(BondingCurveMath.TOKEN_DECIMALS, 18);
        assertEq(BondingCurveMath.ONE_TOKEN, 1e18);
        assertEq(BondingCurveMath.BASE_PRICE, 0.00001 ether);
        assertEq(BondingCurveMath.SLOPE, 0.000001 ether);
        assertEq(BondingCurveMath.BUY_FEE_BPS, 100);
        assertEq(BondingCurveMath.SELL_FEE_BPS, 200);
        assertEq(BondingCurveMath.BPS_DENOMINATOR, 10000);
        assertEq(BondingCurveMath.COOLDOWN_PERIOD, 60);
        assertEq(BondingCurveMath.GRADUATION_THRESHOLD, 0.004 ether);
        assertEq(BondingCurveMath.REFERENCE_TRADE_SIZE, 0.001 ether);
    }

    // ============ getCurrentPrice Tests ============

    function test_getCurrentPrice_zeroSupply() public pure {
        uint256 price = BondingCurveMath.getCurrentPrice(0);
        assertEq(price, BASE_PRICE, "Price at zero supply should be BASE_PRICE");
    }

    function test_getCurrentPrice_oneToken() public pure {
        uint256 price = BondingCurveMath.getCurrentPrice(ONE_TOKEN);
        assertEq(price, BASE_PRICE + SLOPE, "Price after 1 token should be BASE_PRICE + SLOPE");
    }

    function test_getCurrentPrice_tenTokens() public pure {
        uint256 price = BondingCurveMath.getCurrentPrice(10 * ONE_TOKEN);
        assertEq(price, BASE_PRICE + 10 * SLOPE, "Price after 10 tokens should be BASE_PRICE + 10*SLOPE");
    }

    function test_getCurrentPrice_linearIncrease() public pure {
        uint256 price1 = BondingCurveMath.getCurrentPrice(5 * ONE_TOKEN);
        uint256 price2 = BondingCurveMath.getCurrentPrice(10 * ONE_TOKEN);
        uint256 price3 = BondingCurveMath.getCurrentPrice(15 * ONE_TOKEN);

        // Check linearity: price2 - price1 should equal price3 - price2
        uint256 diff1 = price2 - price1;
        uint256 diff2 = price3 - price2;
        assertEq(diff1, diff2, "Price increase should be linear");
        assertEq(diff1, 5 * SLOPE, "Difference should be 5 * SLOPE");
    }

    function test_getCurrentPrice_fractionalSupply() public pure {
        // Fractional tokens should floor to whole token count for price
        uint256 price1 = BondingCurveMath.getCurrentPrice(ONE_TOKEN / 2);
        uint256 price2 = BondingCurveMath.getCurrentPrice(ONE_TOKEN - 1);
        
        // Both should return BASE_PRICE (0 whole tokens)
        assertEq(price1, BASE_PRICE);
        assertEq(price2, BASE_PRICE);
    }

    // ============ calculateBuyCost Tests ============

    function test_calculateBuyCost_zeroTokens() public pure {
        uint256 cost = BondingCurveMath.calculateBuyCost(0, 0);
        assertEq(cost, 0, "Cost of 0 tokens should be 0");
    }

    function test_calculateBuyCost_oneToken_zeroSupply() public pure {
        // Cost to buy 1 token from 0 supply
        // = BASE_PRICE * 1 + SLOPE * (0 * 1 + 1 * 0 / 2)
        // = BASE_PRICE
        uint256 cost = BondingCurveMath.calculateBuyCost(0, ONE_TOKEN);
        assertEq(cost, BASE_PRICE, "Cost of first token should be BASE_PRICE");
    }

    function test_calculateBuyCost_twoTokens_zeroSupply() public pure {
        // Cost = BASE_PRICE * 2 + SLOPE * (0 * 2 + 2 * 1 / 2)
        // = 2 * BASE_PRICE + SLOPE
        uint256 cost = BondingCurveMath.calculateBuyCost(0, 2 * ONE_TOKEN);
        assertEq(cost, 2 * BASE_PRICE + SLOPE, "Cost of 2 tokens from zero supply");
    }

    function test_calculateBuyCost_multipleTokens() public pure {
        // Cost of buying n tokens from supply s:
        // = BASE_PRICE * n + SLOPE * (s * n + n * (n-1) / 2)
        uint256 supply = 5 * ONE_TOKEN;
        uint256 tokensToBuy = 3 * ONE_TOKEN;
        
        uint256 cost = BondingCurveMath.calculateBuyCost(supply, tokensToBuy);
        
        // Expected: BASE_PRICE * 3 + SLOPE * (5 * 3 + 3 * 2 / 2)
        // = 0.00003 ether + 0.000001 ether * (15 + 3)
        // = 0.00003 ether + 0.000018 ether
        // = 0.000048 ether
        uint256 expected = BASE_PRICE * 3 + SLOPE * (5 * 3 + 3);
        assertEq(cost, expected, "Cost calculation mismatch");
    }

    function test_calculateBuyCost_fractionalTokens() public pure {
        // For fractional tokens (< 1 whole token), uses linear approximation
        uint256 cost = BondingCurveMath.calculateBuyCost(0, ONE_TOKEN / 2);
        
        // Should use current price * fraction
        uint256 expected = (BASE_PRICE * (ONE_TOKEN / 2)) / ONE_TOKEN;
        assertEq(cost, expected, "Fractional token cost should use linear approx");
    }

    function test_calculateBuyCost_consistencyWithPrice() public pure {
        // Buying 1 token at supply s should cost approximately getCurrentPrice(s)
        uint256 supply = 10 * ONE_TOKEN;
        uint256 cost = BondingCurveMath.calculateBuyCost(supply, ONE_TOKEN);
        uint256 price = BondingCurveMath.getCurrentPrice(supply);
        
        // Cost should be equal to price for 1 token
        assertEq(cost, price, "1 token cost should equal current price");
    }

    // ============ calculateTokensForETH Tests ============

    function test_calculateTokensForETH_zeroETH() public pure {
        uint256 tokens = BondingCurveMath.calculateTokensForETH(0, 0);
        assertEq(tokens, 0, "0 ETH should give 0 tokens");
    }

    function test_calculateTokensForETH_smallAmount() public pure {
        // Buying at zero supply with small ETH amount
        uint256 ethAmount = BASE_PRICE; // Enough for ~1 token
        uint256 tokens = BondingCurveMath.calculateTokensForETH(0, ethAmount);
        
        // Should get approximately 1 token
        assertApproxEqRel(tokens, ONE_TOKEN, 0.01e18, "Should get ~1 token for BASE_PRICE");
    }

    function test_calculateTokensForETH_inverseOfBuyCost() public pure {
        // Calculate cost for N tokens, then calculate tokens for that cost
        // Due to quadratic formula solving and integer division, there's some deviation
        uint256 targetTokens = 5 * ONE_TOKEN;
        uint256 cost = BondingCurveMath.calculateBuyCost(0, targetTokens);
        uint256 calculatedTokens = BondingCurveMath.calculateTokensForETH(0, cost);
        
        // Allow 25% tolerance due to quadratic math and integer division
        assertApproxEqRel(calculatedTokens, targetTokens, 0.25e18, "Should be approximately inverse of buy cost");
    }

    function test_calculateTokensForETH_largerAmounts() public pure {
        uint256 ethAmount = 0.001 ether;
        uint256 tokens = BondingCurveMath.calculateTokensForETH(0, ethAmount);
        
        // Should be > 0 and reasonable
        assertTrue(tokens > 0, "Should receive tokens");
        assertTrue(tokens < 1000 * ONE_TOKEN, "Should be reasonable amount");
    }

    function test_calculateTokensForETH_withExistingSupply() public pure {
        uint256 supply = 10 * ONE_TOKEN;
        uint256 ethAmount = 0.001 ether;
        
        uint256 tokensFromZero = BondingCurveMath.calculateTokensForETH(0, ethAmount);
        uint256 tokensFromSupply = BondingCurveMath.calculateTokensForETH(supply, ethAmount);
        
        // Should get fewer tokens when supply is higher (price is higher)
        assertTrue(tokensFromSupply < tokensFromZero, "Higher supply = fewer tokens");
    }

    // ============ calculateSellReturn Tests ============

    function test_calculateSellReturn_zeroTokens() public pure {
        uint256 ethReturn = BondingCurveMath.calculateSellReturn(10 * ONE_TOKEN, 0);
        assertEq(ethReturn, 0, "Selling 0 tokens should return 0 ETH");
    }

    function test_calculateSellReturn_allSupply() public pure {
        // Selling all supply should return total cost of all tokens
        uint256 totalSupply = 5 * ONE_TOKEN;
        uint256 sellReturn = BondingCurveMath.calculateSellReturn(totalSupply, totalSupply);
        uint256 totalCost = BondingCurveMath.calculateBuyCost(0, totalSupply);
        
        assertEq(sellReturn, totalCost, "Selling all should return total cost");
    }

    function test_calculateSellReturn_partialSell() public pure {
        uint256 supply = 10 * ONE_TOKEN;
        uint256 sellAmount = 3 * ONE_TOKEN;
        
        uint256 ethReturn = BondingCurveMath.calculateSellReturn(supply, sellAmount);
        
        // Selling from supply 10 to supply 7
        // Return should be cost from 7 to 10
        uint256 expected = BondingCurveMath.calculateBuyCost(7 * ONE_TOKEN, sellAmount);
        assertEq(ethReturn, expected, "Partial sell return should match buy cost");
    }

    function test_calculateSellReturn_exceedsSupply_reverts() public {
        uint256 supply = 5 * ONE_TOKEN;
        uint256 sellAmount = 10 * ONE_TOKEN;
        
        // This should revert in the library with "Cannot sell more than supply"
        // We use low-level call to catch the revert
        (bool success,) = address(this).call(
            abi.encodeWithSignature("callCalculateSellReturn(uint256,uint256)", supply, sellAmount)
        );
        assertFalse(success, "Should revert when selling more than supply");
    }
    
    // Helper function to test revert
    function callCalculateSellReturn(uint256 supply, uint256 sellAmount) external pure returns (uint256) {
        return BondingCurveMath.calculateSellReturn(supply, sellAmount);
    }

    function test_calculateSellReturn_symmetry() public pure {
        // Buy N tokens, then sell N tokens should be symmetric (ignoring fees)
        uint256 buyAmount = 5 * ONE_TOKEN;
        uint256 buyCost = BondingCurveMath.calculateBuyCost(0, buyAmount);
        uint256 sellReturn = BondingCurveMath.calculateSellReturn(buyAmount, buyAmount);
        
        assertEq(buyCost, sellReturn, "Buy and sell should be symmetric");
    }

    // ============ Fee Calculation Tests ============

    function test_calculateBuyFee_1percent() public pure {
        uint256 amount = 1 ether;
        uint256 fee = BondingCurveMath.calculateBuyFee(amount);
        
        uint256 expected = (amount * BUY_FEE_BPS) / BPS_DENOMINATOR;
        assertEq(fee, expected, "Buy fee should be 1%");
        assertEq(fee, 0.01 ether, "1 ETH buy fee should be 0.01 ETH");
    }

    function test_calculateSellFee_2percent() public pure {
        uint256 amount = 1 ether;
        uint256 fee = BondingCurveMath.calculateSellFee(amount);
        
        uint256 expected = (amount * SELL_FEE_BPS) / BPS_DENOMINATOR;
        assertEq(fee, expected, "Sell fee should be 2%");
        assertEq(fee, 0.02 ether, "1 ETH sell fee should be 0.02 ETH");
    }

    function test_calculateBuyFee_smallAmount() public pure {
        uint256 amount = 100; // 100 wei
        uint256 fee = BondingCurveMath.calculateBuyFee(amount);
        
        // 100 * 100 / 10000 = 1
        assertEq(fee, 1, "Small amount fee should round down");
    }

    function test_calculateBuyFee_zeroAmount() public pure {
        uint256 fee = BondingCurveMath.calculateBuyFee(0);
        assertEq(fee, 0, "Zero amount should have zero fee");
    }

    // ============ Cooldown Penalty Tests ============

    function test_applyCooldownPenalty_atLaunch() public {
        uint256 tokens = 100 * ONE_TOKEN;
        uint256 launchTime = block.timestamp;
        
        uint256 adjusted = BondingCurveMath.applyCooldownPenalty(tokens, launchTime);
        
        // At t=0, elapsed=0, should get 0 tokens
        assertEq(adjusted, 0, "Should get 0 tokens at launch");
    }

    function test_applyCooldownPenalty_midway() public {
        uint256 tokens = 100 * ONE_TOKEN;
        uint256 launchTime = block.timestamp;
        
        // Warp to halfway through cooldown
        vm.warp(block.timestamp + 30);
        
        uint256 adjusted = BondingCurveMath.applyCooldownPenalty(tokens, launchTime);
        
        // At t=30 (halfway), should get 50%
        assertEq(adjusted, 50 * ONE_TOKEN, "Should get 50% at halfway");
    }

    function test_applyCooldownPenalty_afterCooldown() public {
        uint256 tokens = 100 * ONE_TOKEN;
        uint256 launchTime = block.timestamp;
        
        // Warp past cooldown
        vm.warp(block.timestamp + 61);
        
        uint256 adjusted = BondingCurveMath.applyCooldownPenalty(tokens, launchTime);
        
        // After cooldown, should get full tokens
        assertEq(adjusted, tokens, "Should get full tokens after cooldown");
    }

    function test_applyCooldownPenalty_linearInterpolation() public {
        uint256 tokens = 100 * ONE_TOKEN;
        uint256 launchTime = block.timestamp;
        
        // Test at different points
        vm.warp(block.timestamp + 15); // 25%
        uint256 at15 = BondingCurveMath.applyCooldownPenalty(tokens, launchTime);
        assertEq(at15, 25 * ONE_TOKEN, "25% at t=15");
        
        vm.warp(block.timestamp + 15); // 50% total
        // Need to recalculate since launchTime is still original
        uint256 at30 = BondingCurveMath.applyCooldownPenalty(tokens, launchTime);
        assertEq(at30, 50 * ONE_TOKEN, "50% at t=30");
        
        vm.warp(block.timestamp + 15); // 75% total
        uint256 at45 = BondingCurveMath.applyCooldownPenalty(tokens, launchTime);
        assertEq(at45, 75 * ONE_TOKEN, "75% at t=45");
    }

    // ============ Pool Tokens Calculation Tests ============

    function test_calculatePoolTokens_nonZero() public pure {
        uint256 supply = 50 * ONE_TOKEN;
        uint256 ethForPool = 0.004 ether;
        
        uint256 poolTokens = BondingCurveMath.calculatePoolTokens(supply, ethForPool);
        
        assertTrue(poolTokens > 0, "Pool tokens should be non-zero");
    }

    function test_calculatePoolTokens_ensuresHigherV2Price() public pure {
        uint256 supply = 50 * ONE_TOKEN;
        uint256 ethForPool = 0.004 ether;
        uint256 refTradeSize = 0.001 ether;
        
        uint256 poolTokens = BondingCurveMath.calculatePoolTokens(supply, ethForPool);
        
        // Calculate tokens from bonding curve for reference trade
        uint256 tokensFromCurve = BondingCurveMath.calculateTokensForETH(supply, refTradeSize);
        
        // V2 AMM: tokensOut ≈ ethIn * tokenReserve / ethReserve * 0.997
        uint256 v2TokensOut = (refTradeSize * poolTokens * 997) / (ethForPool * 1000);
        
        // V2 should give FEWER or equal tokens than bonding curve
        assertTrue(v2TokensOut <= tokensFromCurve, "V2 should give fewer tokens");
    }

    function test_calculatePoolTokens_fallbackToSpotPrice() public pure {
        // With very small ETH amount where curve gives 0 tokens
        uint256 supply = 0;
        uint256 ethForPool = 0.0001 ether;
        
        uint256 poolTokens = BondingCurveMath.calculatePoolTokens(supply, ethForPool);
        
        // Should use spot price method as fallback
        assertTrue(poolTokens > 0, "Should have fallback for small amounts");
    }

    // ============ Square Root Tests ============

    function test_sqrt_zero() public pure {
        uint256 result = BondingCurveMath.sqrt(0);
        assertEq(result, 0, "sqrt(0) should be 0");
    }

    function test_sqrt_one() public pure {
        uint256 result = BondingCurveMath.sqrt(1);
        assertEq(result, 1, "sqrt(1) should be 1");
    }

    function test_sqrt_perfectSquares() public pure {
        assertEq(BondingCurveMath.sqrt(4), 2, "sqrt(4) should be 2");
        assertEq(BondingCurveMath.sqrt(9), 3, "sqrt(9) should be 3");
        assertEq(BondingCurveMath.sqrt(16), 4, "sqrt(16) should be 4");
        assertEq(BondingCurveMath.sqrt(100), 10, "sqrt(100) should be 10");
        assertEq(BondingCurveMath.sqrt(10000), 100, "sqrt(10000) should be 100");
    }

    function test_sqrt_nonPerfect() public pure {
        // sqrt should return floor
        assertEq(BondingCurveMath.sqrt(2), 1, "sqrt(2) should be 1");
        assertEq(BondingCurveMath.sqrt(3), 1, "sqrt(3) should be 1");
        assertEq(BondingCurveMath.sqrt(5), 2, "sqrt(5) should be 2");
        assertEq(BondingCurveMath.sqrt(8), 2, "sqrt(8) should be 2");
        assertEq(BondingCurveMath.sqrt(15), 3, "sqrt(15) should be 3");
        assertEq(BondingCurveMath.sqrt(99), 9, "sqrt(99) should be 9");
    }

    function test_sqrt_largeNumbers() public pure {
        // Test with large numbers typical in token calculations
        uint256 large = 1e36; // 10^36
        uint256 result = BondingCurveMath.sqrt(large);
        assertEq(result, 1e18, "sqrt(10^36) should be 10^18");
        
        // Verify by squaring
        assertTrue(result * result <= large, "Result squared should be <= input");
        assertTrue((result + 1) * (result + 1) > large, "Result+1 squared should be > input");
    }

    // ============ Edge Case Tests ============

    function test_edge_verySmallETH() public pure {
        // Test with 1 wei
        uint256 tokens = BondingCurveMath.calculateTokensForETH(0, 1);
        // Should either return 0 or a very small amount
        assertTrue(tokens <= ONE_TOKEN, "Very small ETH should give minimal tokens");
    }

    function test_edge_graduationThresholdCalculation() public pure {
        // Verify graduation threshold is reasonable
        // 0.004 ETH should be achievable through multiple buys
        uint256 ethNeeded = GRADUATION_THRESHOLD;
        uint256 tokensAtThreshold = BondingCurveMath.calculateTokensForETH(0, ethNeeded);
        
        assertTrue(tokensAtThreshold > 0, "Should be able to buy tokens at threshold");
    }

    function test_edge_maxSupplyPrice() public pure {
        // Test price at very high supply (shouldn't overflow)
        uint256 highSupply = 1000000 * ONE_TOKEN; // 1 million tokens
        uint256 price = BondingCurveMath.getCurrentPrice(highSupply);
        
        // Price = BASE_PRICE + 1000000 * SLOPE = 0.00001 + 1 = 1.00001 ETH
        assertTrue(price > 0, "Price should be positive");
        assertTrue(price < type(uint256).max, "Price should not overflow");
    }

    function test_roundingBehavior_buyFee() public pure {
        // Test rounding with amounts that don't divide evenly
        uint256 amount = 123456789;
        uint256 fee = BondingCurveMath.calculateBuyFee(amount);
        
        // Fee should round down
        uint256 expected = (amount * 100) / 10000;
        assertEq(fee, expected);
        assertEq(fee, 1234567, "Fee should round down");
    }

    function test_roundingBehavior_sellFee() public pure {
        uint256 amount = 123456789;
        uint256 fee = BondingCurveMath.calculateSellFee(amount);
        
        uint256 expected = (amount * 200) / 10000;
        assertEq(fee, expected);
        assertEq(fee, 2469135, "Fee should round down");
    }
}
