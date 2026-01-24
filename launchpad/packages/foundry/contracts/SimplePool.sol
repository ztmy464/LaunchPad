// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SimplePool
 * @notice Simple constant product AMM for graduated tokens
 * @dev Provides x*y=k style liquidity pool with directional fees (1% buy, 2% sell)
 *      This is a simplified pool for testing - in production use Uniswap V4
 */
contract SimplePool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Events ============

    event PoolCreated(address indexed token, uint256 ethAmount, uint256 tokenAmount);
    event Swap(address indexed user, bool isBuy, uint256 amountIn, uint256 amountOut, uint256 fee);
    event LiquidityAdded(address indexed provider, uint256 ethAmount, uint256 tokenAmount);

    // ============ Errors ============

    error PoolExists();
    error PoolNotExists();
    error InsufficientLiquidity();
    error InsufficientOutput();
    error ZeroAmount();
    error TransferFailed();

    // ============ State ============

    struct Pool {
        uint256 ethReserve;
        uint256 tokenReserve;
        bool exists;
    }

    /// @notice Fee for buying tokens (1% = 100 basis points)
    uint256 public constant BUY_FEE_BPS = 100;
    
    /// @notice Fee for selling tokens (2% = 200 basis points)
    uint256 public constant SELL_FEE_BPS = 200;
    
    /// @notice Basis points denominator
    uint256 public constant BPS = 10000;

    /// @notice Token address to pool
    mapping(address => Pool) public pools;

    /// @notice Fee recipient
    address public feeRecipient;

    /// @notice Total fees collected per token
    mapping(address => uint256) public feesCollected;

    // ============ Constructor ============

    constructor() {
        feeRecipient = msg.sender;
    }

    // ============ Pool Creation ============

    /**
     * @notice Create a new pool for a token
     * @param token Token address
     * @param tokenAmount Initial token liquidity (must be approved)
     */
    function createPool(address token, uint256 tokenAmount) external payable nonReentrant {
        if (pools[token].exists) revert PoolExists();
        if (msg.value == 0) revert ZeroAmount();
        if (tokenAmount == 0) revert ZeroAmount();

        // Transfer tokens from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Create pool
        pools[token] = Pool({
            ethReserve: msg.value,
            tokenReserve: tokenAmount,
            exists: true
        });

        emit PoolCreated(token, msg.value, tokenAmount);
    }

    // ============ Trading ============

    /**
     * @notice Buy tokens with ETH
     * @param token Token to buy
     * @param minTokensOut Minimum tokens to receive (slippage protection)
     * @return tokensOut Actual tokens received
     */
    function buyTokens(address token, uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        Pool storage pool = pools[token];
        if (!pool.exists) revert PoolNotExists();
        if (msg.value == 0) revert ZeroAmount();

        // Calculate fee (1% for buys)
        uint256 fee = (msg.value * BUY_FEE_BPS) / BPS;
        uint256 ethIn = msg.value - fee;

        // Calculate output using constant product formula: x * y = k
        // (ethReserve + ethIn) * (tokenReserve - tokensOut) = ethReserve * tokenReserve
        // tokensOut = tokenReserve - (ethReserve * tokenReserve) / (ethReserve + ethIn)
        // tokensOut = tokenReserve * ethIn / (ethReserve + ethIn)
        tokensOut = (pool.tokenReserve * ethIn) / (pool.ethReserve + ethIn);

        if (tokensOut < minTokensOut) revert InsufficientOutput();
        if (tokensOut > pool.tokenReserve) revert InsufficientLiquidity();

        // Update reserves
        pool.ethReserve += ethIn;
        pool.tokenReserve -= tokensOut;
        feesCollected[token] += fee;

        // Transfer tokens to buyer
        IERC20(token).safeTransfer(msg.sender, tokensOut);

        emit Swap(msg.sender, true, msg.value, tokensOut, fee);
    }

    /**
     * @notice Sell tokens for ETH
     * @param token Token to sell
     * @param tokenAmount Tokens to sell (must be approved)
     * @param minEthOut Minimum ETH to receive (slippage protection)
     * @return ethOut Actual ETH received
     */
    function sellTokens(address token, uint256 tokenAmount, uint256 minEthOut) external nonReentrant returns (uint256 ethOut) {
        Pool storage pool = pools[token];
        if (!pool.exists) revert PoolNotExists();
        if (tokenAmount == 0) revert ZeroAmount();

        // Transfer tokens from seller
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Calculate output using constant product formula
        // ethOut = ethReserve * tokenAmount / (tokenReserve + tokenAmount)
        uint256 grossEthOut = (pool.ethReserve * tokenAmount) / (pool.tokenReserve + tokenAmount);
        
        // Calculate fee (2% for sells)
        uint256 fee = (grossEthOut * SELL_FEE_BPS) / BPS;
        ethOut = grossEthOut - fee;

        if (ethOut < minEthOut) revert InsufficientOutput();
        if (grossEthOut > pool.ethReserve) revert InsufficientLiquidity();

        // Update reserves
        pool.ethReserve -= grossEthOut;
        pool.tokenReserve += tokenAmount;
        feesCollected[token] += fee;

        // Transfer ETH to seller
        (bool success, ) = msg.sender.call{value: ethOut}("");
        if (!success) revert TransferFailed();

        emit Swap(msg.sender, false, tokenAmount, ethOut, fee);
    }

    // ============ View Functions ============

    /**
     * @notice Check if pool exists for a token
     */
    function hasPool(address token) external view returns (bool) {
        return pools[token].exists;
    }

    /**
     * @notice Get pool reserves
     */
    function getReserves(address token) external view returns (uint256 ethReserve, uint256 tokenReserve) {
        Pool storage pool = pools[token];
        return (pool.ethReserve, pool.tokenReserve);
    }

    /**
     * @notice Get current price (ETH per token, scaled by 1e18)
     */
    function getPrice(address token) external view returns (uint256) {
        Pool storage pool = pools[token];
        if (!pool.exists || pool.tokenReserve == 0) return 0;
        // price = ethReserve / tokenReserve * 1e18
        return (pool.ethReserve * 1e18) / pool.tokenReserve;
    }

    /**
     * @notice Estimate tokens out for ETH in
     */
    function estimateBuyOutput(address token, uint256 ethIn) external view returns (uint256 tokensOut) {
        Pool storage pool = pools[token];
        if (!pool.exists) return 0;
        
        uint256 fee = (ethIn * BUY_FEE_BPS) / BPS;
        uint256 ethInAfterFee = ethIn - fee;
        
        tokensOut = (pool.tokenReserve * ethInAfterFee) / (pool.ethReserve + ethInAfterFee);
    }

    /**
     * @notice Estimate ETH out for tokens in
     */
    function estimateSellOutput(address token, uint256 tokensIn) external view returns (uint256 ethOut) {
        Pool storage pool = pools[token];
        if (!pool.exists) return 0;
        
        uint256 grossEthOut = (pool.ethReserve * tokensIn) / (pool.tokenReserve + tokensIn);
        uint256 fee = (grossEthOut * SELL_FEE_BPS) / BPS;
        ethOut = grossEthOut - fee;
    }

    // ============ Admin ============

    /**
     * @notice Withdraw collected fees
     */
    function withdrawFees() external {
        uint256 balance = address(this).balance - _totalPooledEth();
        if (balance > 0) {
            (bool success, ) = feeRecipient.call{value: balance}("");
            require(success, "Fee withdrawal failed");
        }
    }

    function _totalPooledEth() internal view returns (uint256) {
        // This is a simplified implementation
        // In production, track total pooled ETH separately
        return 0;
    }

    // ============ Receive ============

    receive() external payable {}
}
