// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SimplePool
 * @notice Simple constant product AMM for graduated tokens
 * @dev Provides x*y=k style liquidity pool with directional fees (1% buy, 2% sell)
 */
contract SimplePool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Events ============

    event PoolCreated(address indexed token, uint256 ethAmount, uint256 tokenAmount, uint256 lpTokens);
    event Swap(address indexed user, bool isBuy, uint256 amountIn, uint256 amountOut, uint256 fee);
    event LiquidityAdded(address indexed token, address indexed provider, uint256 ethAmount, uint256 tokenAmount, uint256 lpTokens);
    event LiquidityRemoved(address indexed token, address indexed provider, uint256 ethAmount, uint256 tokenAmount, uint256 lpBurned);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event EmergencyPoolDrain(address indexed token, address indexed creator, uint256 ethAmount, uint256 tokenAmount);

    // ============ Errors ============

    error PoolExists();
    error PoolNotExists();
    error InsufficientLiquidity();
    error InsufficientOutput();
    error ZeroAmount();
    error TransferFailed();
    error InsufficientLPBalance();
    error Unauthorized();
    error NotTokenCreator();
    error NotAuthorizedFactory();

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

    /// @notice Authorized factory that can create pools with custom creator
    address public authorizedFactory;

    /// @notice Total fees collected per token
    mapping(address => uint256) public feesCollected;

    /// @notice Token address to original pool creator
    mapping(address => address) public tokenCreators;

    /// @notice Minimum liquidity locked forever to prevent division by zero
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice LP token balance: token => provider => LP balance
    mapping(address => mapping(address => uint256)) public liquidity;

    /// @notice Total LP tokens per pool: token => total LP supply
    mapping(address => uint256) public totalLiquidity;

    /// @notice Total ETH held across all pool reserves (for accurate fee calculation)
    uint256 public totalPooledEth;

    // ============ Modifiers ============

    modifier onlyFeeRecipient() {
        if (msg.sender != feeRecipient) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor() {
        feeRecipient = msg.sender;
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the authorized factory address
     * @param _factory Factory address that can create pools with custom creator
     */
    function setAuthorizedFactory(address _factory) external onlyFeeRecipient {
        authorizedFactory = _factory;
    }

    // ============ Pool Creation ============

    /**
     * @notice Create a new pool for a token (factory only)
     * @param token Token address
     * @param tokenAmount Initial token liquidity (must be approved)
     * @return lpTokens LP tokens minted to creator
     * @dev Only callable by authorized factory to prevent front-running attacks
     */
    function createPool(address token, uint256 tokenAmount) external payable nonReentrant returns (uint256 lpTokens) {
        if (msg.sender != authorizedFactory) revert NotAuthorizedFactory();
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

        // Track total pooled ETH for accurate fee calculation
        totalPooledEth += msg.value;

        // Store pool creator for emergency drain
        tokenCreators[token] = msg.sender;

        // Calculate initial LP tokens: sqrt(ethAmount * tokenAmount)
        // Lock MINIMUM_LIQUIDITY forever to prevent division by zero edge cases
        uint256 initialLp = _sqrt(msg.value * tokenAmount);
        if (initialLp <= MINIMUM_LIQUIDITY) revert InsufficientLiquidity();
        
        lpTokens = initialLp - MINIMUM_LIQUIDITY;
        
        // Mint LP tokens - MINIMUM_LIQUIDITY is locked (not assigned to anyone)
        totalLiquidity[token] = initialLp;
        liquidity[token][msg.sender] = lpTokens;

        emit PoolCreated(token, msg.value, tokenAmount, lpTokens);
    }

    /**
     * @notice Create a new pool for a token with a custom creator (factory only)
     * @param token Token address
     * @param tokenAmount Initial token liquidity (must be approved)
     * @param creator The original creator to assign (for emergency drain rights)
     * @return lpTokens LP tokens minted to factory (caller)
     */
    function createPoolWithCreator(address token, uint256 tokenAmount, address creator) external payable nonReentrant returns (uint256 lpTokens) {
        if (msg.sender != authorizedFactory) revert NotAuthorizedFactory();
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

        // Track total pooled ETH for accurate fee calculation
        totalPooledEth += msg.value;

        // Store the ORIGINAL creator for emergency drain rights
        tokenCreators[token] = creator;

        // Calculate initial LP tokens: sqrt(ethAmount * tokenAmount)
        // Lock MINIMUM_LIQUIDITY forever to prevent division by zero edge cases
        uint256 initialLp = _sqrt(msg.value * tokenAmount);
        if (initialLp <= MINIMUM_LIQUIDITY) revert InsufficientLiquidity();
        
        lpTokens = initialLp - MINIMUM_LIQUIDITY;
        
        // Mint LP tokens - MINIMUM_LIQUIDITY is locked (not assigned to anyone)
        totalLiquidity[token] = initialLp;
        liquidity[token][msg.sender] = lpTokens;

        emit PoolCreated(token, msg.value, tokenAmount, lpTokens);
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

        // Update reserves and track total pooled ETH
        pool.ethReserve += ethIn;
        pool.tokenReserve -= tokensOut;
        totalPooledEth += ethIn;
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

        // Update reserves and track total pooled ETH
        pool.ethReserve -= grossEthOut;
        pool.tokenReserve += tokenAmount;
        totalPooledEth -= grossEthOut;
        feesCollected[token] += fee;

        // Transfer ETH to seller
        (bool success, ) = msg.sender.call{value: ethOut}("");
        if (!success) revert TransferFailed();

        emit Swap(msg.sender, false, tokenAmount, ethOut, fee);
    }

    // ============ Liquidity Management ============

    /**
     * @notice Add liquidity to an existing pool
     * @param token Token address
     * @param minLpTokens Minimum LP tokens to receive (slippage protection)
     * @return lpTokens LP tokens minted to provider
     * @dev User sends ETH, tokens are calculated proportionally based on current reserves
     */
    function addLiquidity(address token, uint256 minLpTokens) external payable nonReentrant returns (uint256 lpTokens) {
        Pool storage pool = pools[token];
        if (!pool.exists) revert PoolNotExists();
        if (msg.value == 0) revert ZeroAmount();

        uint256 ethAmount = msg.value;
        
        // Calculate tokens required to maintain current ratio
        // tokensRequired = ethAmount * tokenReserve / ethReserve
        uint256 tokensRequired = (ethAmount * pool.tokenReserve) / pool.ethReserve;
        if (tokensRequired == 0) revert ZeroAmount();

        // Transfer tokens from provider
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensRequired);

        // Calculate LP tokens to mint
        // LP tokens are proportional to the share of liquidity added
        uint256 _totalLiquidity = totalLiquidity[token];
        if (_totalLiquidity == 0) {
            // Should not happen since pool exists, but handle edge case
            lpTokens = _sqrt(ethAmount * tokensRequired) - MINIMUM_LIQUIDITY;
            // Lock minimum liquidity forever (send to zero address conceptually)
            totalLiquidity[token] = lpTokens + MINIMUM_LIQUIDITY;
        } else {
            // LP tokens based on proportion of ETH added (or tokens, should be same ratio)
            lpTokens = (ethAmount * _totalLiquidity) / pool.ethReserve;
        }

        if (lpTokens < minLpTokens) revert InsufficientOutput();

        // Update state and track total pooled ETH
        pool.ethReserve += ethAmount;
        pool.tokenReserve += tokensRequired;
        totalPooledEth += ethAmount;
        liquidity[token][msg.sender] += lpTokens;
        totalLiquidity[token] += lpTokens;

        emit LiquidityAdded(token, msg.sender, ethAmount, tokensRequired, lpTokens);
    }

    /**
     * @notice Remove liquidity from a pool
     * @param token Token address
     * @param lpAmount Amount of LP tokens to burn
     * @param minEthOut Minimum ETH to receive (slippage protection)
     * @param minTokensOut Minimum tokens to receive (slippage protection)
     * @return ethOut ETH returned to provider
     * @return tokensOut Tokens returned to provider
     */
    function removeLiquidity(
        address token,
        uint256 lpAmount,
        uint256 minEthOut,
        uint256 minTokensOut
    ) external nonReentrant returns (uint256 ethOut, uint256 tokensOut) {
        Pool storage pool = pools[token];
        if (!pool.exists) revert PoolNotExists();
        if (lpAmount == 0) revert ZeroAmount();
        if (liquidity[token][msg.sender] < lpAmount) revert InsufficientLPBalance();

        uint256 _totalLiquidity = totalLiquidity[token];
        
        // Calculate proportional share of reserves
        ethOut = (lpAmount * pool.ethReserve) / _totalLiquidity;
        tokensOut = (lpAmount * pool.tokenReserve) / _totalLiquidity;

        if (ethOut < minEthOut) revert InsufficientOutput();
        if (tokensOut < minTokensOut) revert InsufficientOutput();

        // Update state and track total pooled ETH
        liquidity[token][msg.sender] -= lpAmount;
        totalLiquidity[token] -= lpAmount;
        pool.ethReserve -= ethOut;
        pool.tokenReserve -= tokensOut;
        totalPooledEth -= ethOut;

        // Transfer assets to provider
        IERC20(token).safeTransfer(msg.sender, tokensOut);
        
        (bool success, ) = msg.sender.call{value: ethOut}("");
        if (!success) revert TransferFailed();

        emit LiquidityRemoved(token, msg.sender, ethOut, tokensOut, lpAmount);
    }

    /**
     * @notice Square root function for initial liquidity calculation
     * @dev Uses Babylonian method
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
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

    /**
     * @notice Get LP balance for a provider
     * @param token Token address
     * @param provider Provider address
     * @return LP token balance
     */
    function getLiquidity(address token, address provider) external view returns (uint256) {
        return liquidity[token][provider];
    }

    /**
     * @notice Get total LP tokens for a pool
     * @param token Token address
     * @return Total LP token supply
     */
    function getTotalLiquidity(address token) external view returns (uint256) {
        return totalLiquidity[token];
    }

    /**
     * @notice Estimate tokens required and LP tokens received for adding liquidity
     * @param token Token address
     * @param ethAmount ETH amount to add
     * @return tokensRequired Tokens needed to match the ETH
     * @return lpTokensOut LP tokens that will be minted
     */
    function estimateAddLiquidity(address token, uint256 ethAmount) external view returns (uint256 tokensRequired, uint256 lpTokensOut) {
        Pool storage pool = pools[token];
        if (!pool.exists || ethAmount == 0) return (0, 0);
        
        // Calculate tokens required to maintain ratio
        tokensRequired = (ethAmount * pool.tokenReserve) / pool.ethReserve;
        
        // Calculate LP tokens
        uint256 _totalLiquidity = totalLiquidity[token];
        if (_totalLiquidity == 0) {
            lpTokensOut = _sqrt(ethAmount * tokensRequired);
            if (lpTokensOut > MINIMUM_LIQUIDITY) {
                lpTokensOut -= MINIMUM_LIQUIDITY;
            } else {
                lpTokensOut = 0;
            }
        } else {
            lpTokensOut = (ethAmount * _totalLiquidity) / pool.ethReserve;
        }
    }

    /**
     * @notice Estimate ETH and tokens received for removing liquidity
     * @param token Token address
     * @param lpAmount LP tokens to burn
     * @return ethOut ETH that will be returned
     * @return tokensOut Tokens that will be returned
     */
    function estimateRemoveLiquidity(address token, uint256 lpAmount) external view returns (uint256 ethOut, uint256 tokensOut) {
        Pool storage pool = pools[token];
        uint256 _totalLiquidity = totalLiquidity[token];
        if (!pool.exists || _totalLiquidity == 0 || lpAmount == 0) return (0, 0);
        
        ethOut = (lpAmount * pool.ethReserve) / _totalLiquidity;
        tokensOut = (lpAmount * pool.tokenReserve) / _totalLiquidity;
    }

    // ============ Admin ============

    /**
     * @notice Withdraw collected fees (only fee recipient)
     * @dev Calculates fees as contract balance minus all pool reserves
     */
    function withdrawFees() external onlyFeeRecipient {
        uint256 pooledEth = _totalPooledEth();
        uint256 contractBalance = address(this).balance;
        
        // Fees = total balance - pooled ETH in reserves
        if (contractBalance <= pooledEth) return;
        
        uint256 feeBalance = contractBalance - pooledEth;
        if (feeBalance > 0) {
            (bool success, ) = feeRecipient.call{value: feeBalance}("");
            if (!success) revert TransferFailed();
            emit FeesWithdrawn(feeRecipient, feeBalance);
        }
    }

    /**
     * @notice Update fee recipient (only current fee recipient)
     * @param newRecipient New fee recipient address
     */
    function setFeeRecipient(address newRecipient) external onlyFeeRecipient {
        if (newRecipient == address(0)) revert ZeroAmount();
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @notice Calculate total ETH held in pool reserves
     * @dev This is used to calculate withdrawable fees
     */
    function _totalPooledEth() internal view returns (uint256) {
        return totalPooledEth;
    }

    /**
     * @notice Get total fees collected for a specific token's pool
     * @param token Token address
     * @return Total fees collected from that pool
     */
    function getFeesCollected(address token) external view returns (uint256) {
        return feesCollected[token];
    }

    // ============ Emergency ============

    /**
     * @notice Emergency drain pool (for testing)
     * @param token Token address to drain
     * @dev Only callable by the original pool creator
     */
    function emergencyDrainPool(address token) external nonReentrant {
        Pool storage pool = pools[token];
        if (!pool.exists) revert PoolNotExists();
        if (msg.sender != tokenCreators[token]) revert NotTokenCreator();

        uint256 ethAmount = pool.ethReserve;
        uint256 tokenAmount = pool.tokenReserve;

        // Update state and track total pooled ETH
        pool.ethReserve = 0;
        pool.tokenReserve = 0;
        totalPooledEth -= ethAmount;

        if (tokenAmount > 0) {
            IERC20(token).safeTransfer(msg.sender, tokenAmount);
        }

        if (ethAmount > 0) {
            (bool success, ) = msg.sender.call{value: ethAmount}("");
            if (!success) revert TransferFailed();
        }

        emit EmergencyPoolDrain(token, msg.sender, ethAmount, tokenAmount);
    }

    // ============ Receive ============

    receive() external payable {}
}
