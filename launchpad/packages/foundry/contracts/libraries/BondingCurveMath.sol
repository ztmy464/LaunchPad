// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BondingCurveMath
 * @notice Library for calculating bonding curve prices using a linear curve
 * @dev Price formula: price(supply) = BASE_PRICE + SLOPE * supply
 *      All token amounts are in 18 decimals (1 token = 1e18)
 *      The math works in "whole token" units internally, then scales to 18 decimals
 */
library BondingCurveMath {
    /// @notice Token decimals (18 for standard ERC20)
    uint256 public constant TOKEN_DECIMALS = 18;
    uint256 public constant ONE_TOKEN = 10 ** TOKEN_DECIMALS;

    /// @notice Base price per whole token in wei (0.00001 ETH per token)
    uint256 public constant BASE_PRICE = 0.00001 ether;

    /// @notice Price increase per whole token in wei
    /// @dev With 0.000001 ETH slope, price doubles after ~10 tokens bought
    uint256 public constant SLOPE = 0.000001 ether;

    /// @notice Buy fee in basis points (1% = 100 bps)
    uint256 public constant BUY_FEE_BPS = 100;

    /// @notice Sell fee in basis points (2% = 200 bps)
    uint256 public constant SELL_FEE_BPS = 200;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Cooldown period for sniper protection (1 minute)
    uint256 public constant COOLDOWN_PERIOD = 60;

    /// @notice Reserve balance threshold for graduation to Uniswap V4
    /// @dev Graduation triggers when reserveBalance >= 0.02 ETH (~$50 on Base)
    uint256 public constant GRADUATION_THRESHOLD = 0.02 ether;

    /// @notice Reference trade size for pool calibration (0.001 ETH)
    /// @dev Used to calculate pool tokens so first pool trade matches last curve trade
    uint256 public constant REFERENCE_TRADE_SIZE = 0.001 ether;

    /**
     * @notice Calculate tokens needed for pool to match bonding curve pricing
     * @param currentSupplyWei Current token supply in wei
     * @param ethForPool ETH going into the pool
     * @return poolTokens Tokens to add to pool
     * @dev Calculates pool tokens so a reference trade on V2 gives FEWER tokens
     *      than the bonding curve would have given. This ensures:
     *      1. No arbitrage opportunity at graduation
     *      2. Price continuity (V2 is slightly more expensive)
     *      3. Accounts for V2's 0.3% swap fee
     */
    function calculatePoolTokens(uint256 currentSupplyWei, uint256 ethForPool) internal pure returns (uint256) {
        // Calculate what the bonding curve would give for a reference trade
        // This is the target output we want to match (or be slightly below)
        uint256 tokensFromCurve = calculateTokensForETH(currentSupplyWei, REFERENCE_TRADE_SIZE);
        
        // If no tokens would be received, fall back to spot price method
        if (tokensFromCurve == 0) {
            uint256 spotPrice = getCurrentPrice(currentSupplyWei);
            return (ethForPool * ONE_TOKEN) / spotPrice;
        }
        
        // V2 AMM formula for small trades (ignoring slippage for small reference):
        // tokensOut ≈ ethIn * tokenReserve / ethReserve * 0.997 (due to 0.3% fee)
        //
        // We want V2 to give FEWER or equal tokens:
        // REFERENCE_TRADE_SIZE * poolTokens / ethForPool * 0.997 <= tokensFromCurve
        //
        // Solving for poolTokens:
        // poolTokens <= tokensFromCurve * ethForPool / (REFERENCE_TRADE_SIZE * 0.997)
        // poolTokens <= tokensFromCurve * ethForPool * 1000 / (REFERENCE_TRADE_SIZE * 997)
        //
        // We use 950 instead of 1000 to add a 5% safety margin, ensuring V2 is definitely
        // more expensive than the bonding curve exit price
        
        return (tokensFromCurve * ethForPool * 950) / (REFERENCE_TRADE_SIZE * 1000);
    }

    /**
     * @notice Calculate the current price per token at a given supply
     * @param supplyWei Current token supply in wei (18 decimals)
     * @return price Price per whole token in wei
     */
    function getCurrentPrice(uint256 supplyWei) internal pure returns (uint256) {
        // Convert supply from 18 decimals to whole tokens
        uint256 supplyTokens = supplyWei / ONE_TOKEN;
        return BASE_PRICE + (SLOPE * supplyTokens);
    }

    /**
     * @notice Calculate the cost to buy a specific number of tokens
     * @param currentSupplyWei Current token supply in wei (18 decimals)
     * @param tokensToBuyWei Number of tokens to buy in wei (18 decimals)
     * @return cost Total cost in ETH wei (before fees)
     */
    function calculateBuyCost(uint256 currentSupplyWei, uint256 tokensToBuyWei) internal pure returns (uint256) {
        if (tokensToBuyWei == 0) return 0;

        // Convert to whole token units for calculation
        uint256 s = currentSupplyWei / ONE_TOKEN;
        uint256 n = tokensToBuyWei / ONE_TOKEN;
        
        if (n == 0) {
            // For fractional tokens, use simple linear approximation
            uint256 price = BASE_PRICE + (SLOPE * s);
            return (price * tokensToBuyWei) / ONE_TOKEN;
        }

        // Cost = BASE_PRICE * n + SLOPE * (s * n + n * (n - 1) / 2)
        uint256 baseCost = BASE_PRICE * n;
        uint256 slopeCost = SLOPE * (s * n + (n * (n - 1)) / 2);

        return baseCost + slopeCost;
    }

    /**
     * @notice Calculate how many tokens can be bought with a given amount of ETH
     * @param currentSupplyWei Current token supply in wei (18 decimals)
     * @param ethAmount Amount of ETH to spend (after fees)
     * @return tokensWei Number of tokens in wei (18 decimals)
     */
    function calculateTokensForETH(uint256 currentSupplyWei, uint256 ethAmount) internal pure returns (uint256) {
        if (ethAmount == 0) return 0;

        // Convert current supply to whole tokens
        uint256 s = currentSupplyWei / ONE_TOKEN;

        // Solve quadratic: SLOPE/2 * n^2 + (BASE_PRICE + SLOPE*s) * n - ethAmount = 0
        // Multiply by 2: SLOPE * n^2 + 2*(BASE_PRICE + SLOPE*s) * n - 2*ethAmount = 0
        // Using quadratic formula: n = (-b + sqrt(b^2 + 4ac)) / 2a
        // where a = SLOPE, b = 2*(BASE_PRICE + SLOPE*s), c = 2*ethAmount

        uint256 a = SLOPE;
        uint256 b = 2 * (BASE_PRICE + SLOPE * s);
        uint256 c = 2 * ethAmount;

        // discriminant = b^2 + 4*a*c
        uint256 discriminant = b * b + 4 * a * c;
        uint256 sqrtDisc = sqrt(discriminant);

        // n = (sqrt(discriminant) - b) / (2*a)
        // Note: sqrtDisc > b always because c > 0
        uint256 nTokens = (sqrtDisc - b) / (2 * a);

        // For sub-token amounts (less than 1 whole token), use linear approximation
        if (nTokens == 0) {
            uint256 currentPrice = BASE_PRICE + (SLOPE * s);
            return (ethAmount * ONE_TOKEN) / currentPrice;
        }

        // Convert back to wei (18 decimals)
        return nTokens * ONE_TOKEN;
    }

    /**
     * @notice Calculate the ETH received when selling tokens
     * @param currentSupplyWei Current token supply in wei (18 decimals)
     * @param tokensToSellWei Number of tokens to sell in wei (18 decimals)
     * @return ethAmount Amount of ETH received (before fees)
     */
    function calculateSellReturn(uint256 currentSupplyWei, uint256 tokensToSellWei) internal pure returns (uint256) {
        require(tokensToSellWei <= currentSupplyWei, "Cannot sell more than supply");
        if (tokensToSellWei == 0) return 0;

        // Selling is the reverse of buying
        // Return = integral from (supply - tokens) to supply of price(x) dx
        uint256 newSupplyWei = currentSupplyWei - tokensToSellWei;

        // Cost from newSupply to currentSupply (this is what seller receives)
        return calculateBuyCost(newSupplyWei, tokensToSellWei);
    }

    /**
     * @notice Apply cooldown penalty to token amount
     * @param tokens Original token amount
     * @param launchTime Token launch timestamp
     * @return adjustedTokens Tokens after cooldown penalty
     */
    function applyCooldownPenalty(
        uint256 tokens,
        uint256 launchTime
    ) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - launchTime;

        if (elapsed >= COOLDOWN_PERIOD) {
            return tokens;
        }

        // Linear interpolation: tokens * (elapsed / COOLDOWN_PERIOD)
        return (tokens * elapsed) / COOLDOWN_PERIOD;
    }

    /**
     * @notice Calculate buy fee
     * @param amount Amount to calculate fee on
     * @return fee Fee amount
     */
    function calculateBuyFee(uint256 amount) internal pure returns (uint256) {
        return (amount * BUY_FEE_BPS) / BPS_DENOMINATOR;
    }

    /**
     * @notice Calculate sell fee
     * @param amount Amount to calculate fee on
     * @return fee Fee amount
     */
    function calculateSellFee(uint256 amount) internal pure returns (uint256) {
        return (amount * SELL_FEE_BPS) / BPS_DENOMINATOR;
    }

    /**
     * @notice Integer square root using Newton's method
     * @param x Value to take square root of
     * @return y Square root of x
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
