// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IUniswapV2Router02
 * @notice Minimal interface for Uniswap V2 Router
 */
interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);
    
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
    
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
    
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
}

/**
 * @title IUniswapV2Factory
 * @notice Minimal interface for Uniswap V2 Factory
 */
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/**
 * @title IUniswapV2Pair
 * @notice Minimal interface for Uniswap V2 Pair
 */
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title CreatorFeeRouter
 * @notice Wraps Uniswap V2 swaps with creator fees for launchpad tokens
 * @dev Uses real Uniswap V2 pools for universal compatibility
 *      - 2% fee on buys and sells when using this router
 *      - Users can bypass fees by trading directly on Uniswap
 *      - Fees go to the token creator's treasury
 */
contract CreatorFeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Fee in basis points (2% = 200 bps)
    uint256 public constant FEE_BPS = 200;
    
    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Immutables ============

    /// @notice Uniswap V2 Router
    IUniswapV2Router02 public immutable v2Router;
    
    /// @notice Uniswap V2 Factory
    IUniswapV2Factory public immutable v2Factory;
    
    /// @notice WETH address
    address public immutable WETH;

    /// @notice Deployer address (only one who can set authorized factory)
    address public immutable deployer;

    // ============ State ============

    /// @notice Authorized factory that can register tokens
    address public authorizedFactory;

    /// @notice Mapping from token to creator treasury address
    mapping(address => address) public tokenCreators;
    
    /// @notice Accumulated fees per token (withdrawable by creator)
    mapping(address => uint256) public accumulatedFees;

    // ============ Events ============

    event TokenRegistered(address indexed token, address indexed creator);
    event SwapWithFee(
        address indexed user,
        address indexed token,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event FeesWithdrawn(address indexed token, address indexed creator, uint256 amount);
    event FeesDeposited(address indexed token, uint256 amount);

    // ============ Errors ============

    error TokenNotRegistered();
    error AlreadyRegistered();
    error InvalidAddress();
    error InsufficientOutput();
    error TransferFailed();
    error NotCreator();
    error NoFeesToWithdraw();
    error NotAuthorizedFactory();
    error NotDeployer();

    // ============ Constructor ============

    /**
     * @notice Initialize with V2 Router address
     * @param _v2Router Uniswap V2 Router address
     * @param _v2Factory Uniswap V2 Factory address
     */
    constructor(address _v2Router, address _v2Factory) {
        if (_v2Router == address(0) || _v2Factory == address(0)) revert InvalidAddress();
        
        v2Router = IUniswapV2Router02(_v2Router);
        v2Factory = IUniswapV2Factory(_v2Factory);
        WETH = v2Router.WETH();
        deployer = msg.sender;
    }

    // ============ Admin ============

    /**
     * @notice Set the authorized factory address
     * @param _factory Factory address that can register tokens
     * @dev Can only be called by deployer, and only once (when authorizedFactory is zero)
     */
    function setAuthorizedFactory(address _factory) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (authorizedFactory != address(0)) revert AlreadyRegistered();
        if (_factory == address(0)) revert InvalidAddress();
        authorizedFactory = _factory;
    }

    // ============ Registration ============

    /**
     * @notice Register a token with its creator for fee collection
     * @param token Token address
     * @param creator Creator/treasury address to receive fees
     * @dev Only callable by authorized factory to prevent front-running attacks
     */
    function registerToken(address token, address creator) external {
        if (msg.sender != authorizedFactory) revert NotAuthorizedFactory();
        if (token == address(0) || creator == address(0)) revert InvalidAddress();
        if (tokenCreators[token] != address(0)) revert AlreadyRegistered();
        
        tokenCreators[token] = creator;
        emit TokenRegistered(token, creator);
    }

    // ============ Fee Deposit ============

    /**
     * @notice Deposit fees for a token (callable by LaunchToken during buys/sells)
     * @param token Token address the fees are for
     * @dev Allows bonding curve fees to accumulate in the same place as V2 fees
     */
    function depositFees(address token) external payable {
        if (msg.value == 0) revert InvalidAddress();
        if (tokenCreators[token] == address(0)) revert TokenNotRegistered();
        
        accumulatedFees[token] += msg.value;
        emit FeesDeposited(token, msg.value);
    }

    // ============ Swap Functions ============

    /**
     * @notice Buy tokens with ETH (applies 2% fee)
     * @param token Token to buy
     * @param minTokensOut Minimum tokens to receive (slippage protection)
     * @param deadline Transaction deadline
     * @return tokensOut Actual tokens received
     */
    function buyTokensWithFee(
        address token,
        uint256 minTokensOut,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 tokensOut) {
        if (tokenCreators[token] == address(0)) revert TokenNotRegistered();
        if (msg.value == 0) revert InvalidAddress();

        // Calculate fee (2%)
        uint256 fee = (msg.value * FEE_BPS) / BPS_DENOMINATOR;
        uint256 ethForSwap = msg.value - fee;

        // Accumulate fee
        accumulatedFees[token] += fee;

        // Build path: WETH -> Token
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = token;

        // Execute swap
        uint[] memory amounts = v2Router.swapExactETHForTokens{value: ethForSwap}(
            minTokensOut,
            path,
            msg.sender,
            deadline
        );

        tokensOut = amounts[1];
        
        emit SwapWithFee(msg.sender, token, true, msg.value, tokensOut, fee);
    }

    /**
     * @notice Sell tokens for ETH (applies 2% fee)
     * @param token Token to sell
     * @param tokenAmount Amount of tokens to sell
     * @param minEthOut Minimum ETH to receive (slippage protection)
     * @param deadline Transaction deadline
     * @return ethOut Actual ETH received (after fee)
     */
    function sellTokensWithFee(
        address token,
        uint256 tokenAmount,
        uint256 minEthOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 ethOut) {
        if (tokenCreators[token] == address(0)) revert TokenNotRegistered();
        if (tokenAmount == 0) revert InvalidAddress();

        // Transfer tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Approve router
        IERC20(token).forceApprove(address(v2Router), tokenAmount);

        // Build path: Token -> WETH
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WETH;

        // Execute swap - receive ETH to this contract first
        uint[] memory amounts = v2Router.swapExactTokensForETH(
            tokenAmount,
            0, // We'll check minEthOut after fee
            path,
            address(this),
            deadline
        );

        uint256 grossEth = amounts[1];

        // Calculate fee (2%)
        uint256 fee = (grossEth * FEE_BPS) / BPS_DENOMINATOR;
        ethOut = grossEth - fee;

        if (ethOut < minEthOut) revert InsufficientOutput();

        // Accumulate fee
        accumulatedFees[token] += fee;

        // Send ETH to user
        (bool success, ) = msg.sender.call{value: ethOut}("");
        if (!success) revert TransferFailed();

        emit SwapWithFee(msg.sender, token, false, tokenAmount, ethOut, fee);
    }

    // ============ Fee Withdrawal ============

    /**
     * @notice Withdraw accumulated fees to creator
     * @param token Token to withdraw fees for
     */
    function withdrawFees(address token) external nonReentrant {
        address creator = tokenCreators[token];
        if (creator == address(0)) revert TokenNotRegistered();
        if (msg.sender != creator) revert NotCreator();

        uint256 fees = accumulatedFees[token];
        if (fees == 0) revert NoFeesToWithdraw();

        accumulatedFees[token] = 0;

        (bool success, ) = creator.call{value: fees}("");
        if (!success) revert TransferFailed();

        emit FeesWithdrawn(token, creator, fees);
    }

    // ============ View Functions ============

    /**
     * @notice Get the V2 pair address for a token
     * @param token Token address
     * @return pair V2 pair address (token/WETH)
     */
    function getPair(address token) external view returns (address) {
        return v2Factory.getPair(token, WETH);
    }

    /**
     * @notice Check if a pair exists for a token
     * @param token Token address
     * @return exists True if pair exists
     */
    function hasPair(address token) external view returns (bool) {
        return v2Factory.getPair(token, WETH) != address(0);
    }

    /**
     * @notice Get pool reserves
     * @param token Token address
     * @return ethReserve ETH reserve
     * @return tokenReserve Token reserve
     */
    function getReserves(address token) external view returns (uint256 ethReserve, uint256 tokenReserve) {
        address pair = v2Factory.getPair(token, WETH);
        if (pair == address(0)) return (0, 0);

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        
        // Determine which reserve is which based on token ordering
        if (IUniswapV2Pair(pair).token0() == WETH) {
            ethReserve = uint256(reserve0);
            tokenReserve = uint256(reserve1);
        } else {
            ethReserve = uint256(reserve1);
            tokenReserve = uint256(reserve0);
        }
    }

    /**
     * @notice Estimate tokens out for ETH in (including fee)
     * @param token Token address
     * @param ethIn ETH amount
     * @return tokensOut Estimated tokens (after 2% fee on ETH)
     */
    function estimateBuyOutput(address token, uint256 ethIn) external view returns (uint256 tokensOut) {
        if (ethIn == 0) return 0;

        // Calculate fee
        uint256 fee = (ethIn * FEE_BPS) / BPS_DENOMINATOR;
        uint256 ethForSwap = ethIn - fee;

        // Get V2 quote
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = token;

        try v2Router.getAmountsOut(ethForSwap, path) returns (uint[] memory amounts) {
            tokensOut = amounts[1];
        } catch {
            tokensOut = 0;
        }
    }

    /**
     * @notice Estimate ETH out for tokens in (including fee)
     * @param token Token address
     * @param tokensIn Token amount
     * @return ethOut Estimated ETH (after 2% fee on output)
     */
    function estimateSellOutput(address token, uint256 tokensIn) external view returns (uint256 ethOut) {
        if (tokensIn == 0) return 0;

        // Get V2 quote
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WETH;

        try v2Router.getAmountsOut(tokensIn, path) returns (uint[] memory amounts) {
            uint256 grossEth = amounts[1];
            // Apply fee
            uint256 fee = (grossEth * FEE_BPS) / BPS_DENOMINATOR;
            ethOut = grossEth - fee;
        } catch {
            ethOut = 0;
        }
    }

    /**
     * @notice Get creator address for a token
     * @param token Token address
     * @return creator Creator/treasury address
     */
    function getCreator(address token) external view returns (address) {
        return tokenCreators[token];
    }

    /**
     * @notice Check if token is registered
     * @param token Token address
     * @return registered True if registered
     */
    function isRegistered(address token) external view returns (bool) {
        return tokenCreators[token] != address(0);
    }

    // ============ Receive ETH ============

    receive() external payable {}
}
