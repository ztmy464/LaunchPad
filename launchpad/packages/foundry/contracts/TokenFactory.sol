// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./LaunchToken.sol";
import "./CreatorFeeRouter.sol";
import "./libraries/BondingCurveMath.sol";

/**
 * @title TokenFactory
 * @notice Factory for deploying LaunchToken instances using ERC-1167 minimal proxy pattern
 * @dev Each token deployment costs ~45 bytes instead of full contract bytecode
 *      Handles graduation funds from tokens for Uniswap V2 pool creation
 */
contract TokenFactory is Ownable {
    using Clones for address;
    using SafeERC20 for IERC20;

    // ============ Events ============

    event TokenLaunched(
        address indexed token,
        string name,
        string symbol,
        address indexed creator,
        uint256 timestamp
    );

    event TradeFeeHookUpdated(address indexed oldHook, address indexed newHook);
    
    event GraduationFundsReceived(address indexed token, uint256 amount);
    
    event GraduationFundsWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    
    event GraduatedPoolCreated(address indexed token, address indexed pair, uint256 ethAmount, uint256 tokenAmount, uint256 liquidity);
    
    event V2RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event FeeRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event EmergencyGraduationWithdraw(address indexed token, address indexed creator, uint256 amount);
    event PoolDrained(address indexed token, address indexed creator, uint256 ethAmount, uint256 tokenAmount);

    // ============ Errors ============

    error EmptyName();
    error EmptySymbol();
    error InvalidHook();
    error NotLaunchedToken();
    error InsufficientFunds();
    error TransferFailed();
    error NotGraduated();
    error PoolAlreadyExists();
    error V2RouterNotSet();
    error FeeRouterNotSet();
    error NotTokenCreator();
    error NoPoolExists();

    // ============ State Variables ============

    /// @notice Implementation contract for LaunchToken (all proxies delegate to this)
    address public immutable tokenImplementation;

    /// @notice Shared Uniswap V4 trade fee hook (deployed once, used by all pools)
    address public tradeFeeHook;

    /// @notice Array of all launched tokens
    address[] public launchedTokens;

    /// @notice Mapping from token address to whether it was launched by this factory
    mapping(address => bool) public isLaunchedToken;

    /// @notice Mapping from creator to their launched tokens
    mapping(address => address[]) public tokensByCreator;
    
    /// @notice Mapping from token to graduation funds received
    mapping(address => uint256) public graduationFunds;
    
    /// @notice Uniswap V2 Router for adding liquidity
    address public v2Router;
    
    /// @notice CreatorFeeRouter for fee-wrapped swaps
    address public feeRouter;
    
    /// @notice Mapping from token to V2 pair address
    mapping(address => address) public tokenPairs;

    // ============ Constructor ============

    /**
     * @notice Deploy factory with implementation and hook
     * @param _tradeFeeHook Address of the shared V4 trade fee hook
     */
    constructor(address _tradeFeeHook) Ownable(msg.sender) {
        // Deploy the implementation contract
        tokenImplementation = address(new LaunchToken());
        tradeFeeHook = _tradeFeeHook;
    }

    // ============ Token Creation ============

    /**
     * @notice Launch a new token with bonding curve
     * @param name Token name
     * @param symbol Token symbol
     * @return token Address of the newly created token
     */
    function createToken(
        string memory name,
        string memory symbol
    ) external returns (address token) {
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(symbol).length == 0) revert EmptySymbol();
        if (v2Router == address(0)) revert V2RouterNotSet();

        // Clone the implementation (creates minimal proxy)
        token = tokenImplementation.clone();

        // Get V2 factory and WETH for computing expected pair address
        address wethAddr = IUniswapV2Router02(v2Router).WETH();
        address v2FactoryAddr = IUniswapV2Router02(v2Router).factory();

        // Initialize the clone with V2 addresses for pair blocking
        LaunchToken(payable(token)).initialize(
            name,
            symbol,
            msg.sender,
            tradeFeeHook,
            v2FactoryAddr,
            wethAddr
        );

        // Track the token
        launchedTokens.push(token);
        isLaunchedToken[token] = true;
        tokensByCreator[msg.sender].push(token);

        // Set fee router on token and register with CreatorFeeRouter for unified fee collection
        if (feeRouter != address(0)) {
            LaunchToken(payable(token)).setFeeRouter(feeRouter);
            CreatorFeeRouter(payable(feeRouter)).registerToken(token, msg.sender);
        }

        emit TokenLaunched(token, name, symbol, msg.sender, block.timestamp);
    }

    /**
     * @notice Launch a new token with deterministic address using CREATE2
     * @param name Token name
     * @param symbol Token symbol
     * @param salt Salt for deterministic deployment
     * @return token Address of the newly created token
     */
    function createTokenDeterministic(
        string memory name,
        string memory symbol,
        bytes32 salt
    ) external returns (address token) {
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(symbol).length == 0) revert EmptySymbol();
        if (v2Router == address(0)) revert V2RouterNotSet();

        // Clone with deterministic address
        token = tokenImplementation.cloneDeterministic(salt);

        // Get V2 factory and WETH for computing expected pair address
        address wethAddr = IUniswapV2Router02(v2Router).WETH();
        address v2FactoryAddr = IUniswapV2Router02(v2Router).factory();

        // Initialize the clone with V2 addresses for pair blocking
        LaunchToken(payable(token)).initialize(
            name,
            symbol,
            msg.sender,
            tradeFeeHook,
            v2FactoryAddr,
            wethAddr
        );

        // Track the token
        launchedTokens.push(token);
        isLaunchedToken[token] = true;
        tokensByCreator[msg.sender].push(token);

        // Set fee router on token and register with CreatorFeeRouter for unified fee collection
        if (feeRouter != address(0)) {
            LaunchToken(payable(token)).setFeeRouter(feeRouter);
            CreatorFeeRouter(payable(feeRouter)).registerToken(token, msg.sender);
        }

        emit TokenLaunched(token, name, symbol, msg.sender, block.timestamp);
    }

    /**
     * @notice Predict the address of a deterministically deployed token
     * @param salt Salt for deployment
     * @return predicted Predicted address
     */
    function predictTokenAddress(bytes32 salt) external view returns (address predicted) {
        return tokenImplementation.predictDeterministicAddress(salt);
    }

    // ============ View Functions ============

    /**
     * @notice Get total number of launched tokens
     * @return count Number of tokens
     */
    function totalTokens() external view returns (uint256) {
        return launchedTokens.length;
    }

    /**
     * @notice Get tokens launched by a specific creator
     * @param creator Creator address
     * @return tokens Array of token addresses
     */
    function getTokensByCreator(address creator) external view returns (address[] memory) {
        return tokensByCreator[creator];
    }

    /**
     * @notice Get all launched tokens with pagination
     * @param offset Starting index
     * @param limit Maximum number of tokens to return
     * @return tokens Array of token addresses
     */
    function getTokensPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory tokens) {
        uint256 total = launchedTokens.length;
        if (offset >= total) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        tokens = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            tokens[i - offset] = launchedTokens[i];
        }
    }

    /**
     * @notice Get token info for multiple tokens
     * @param tokenAddresses Array of token addresses
     * @return names Array of names
     * @return symbols Array of symbols
     * @return supplies Array of total supplies
     * @return treasuries Array of treasury balances
     * @return graduatedFlags Array of graduation status
     */
    function getTokensInfo(address[] calldata tokenAddresses)
        external
        view
        returns (
            string[] memory names,
            string[] memory symbols,
            uint256[] memory supplies,
            uint256[] memory treasuries,
            bool[] memory graduatedFlags
        )
    {
        uint256 len = tokenAddresses.length;
        names = new string[](len);
        symbols = new string[](len);
        supplies = new uint256[](len);
        treasuries = new uint256[](len);
        graduatedFlags = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            LaunchToken token = LaunchToken(payable(tokenAddresses[i]));
            names[i] = token.name();
            symbols[i] = token.symbol();
            supplies[i] = token.totalSupply();
            treasuries[i] = token.treasury();
            graduatedFlags[i] = token.graduated();
        }
    }

    // ============ BondingCurve Constants Getters ============

    /**
     * @notice Get the graduation threshold (ETH required for graduation)
     * @return threshold Graduation threshold in wei
     */
    function getGraduationThreshold() external pure returns (uint256) {
        return BondingCurveMath.GRADUATION_THRESHOLD;
    }

    /**
     * @notice Get the cooldown period for sniper protection
     * @return period Cooldown period in seconds
     */
    function getCooldownPeriod() external pure returns (uint256) {
        return BondingCurveMath.COOLDOWN_PERIOD;
    }

    /**
     * @notice Get the buy fee in basis points
     * @return feeBps Buy fee (100 = 1%)
     */
    function getBuyFeeBps() external pure returns (uint256) {
        return BondingCurveMath.BUY_FEE_BPS;
    }

    /**
     * @notice Get the sell fee in basis points
     * @return feeBps Sell fee (200 = 2%)
     */
    function getSellFeeBps() external pure returns (uint256) {
        return BondingCurveMath.SELL_FEE_BPS;
    }

    /**
     * @notice Get the base price per token
     * @return price Base price in wei
     */
    function getBasePrice() external pure returns (uint256) {
        return BondingCurveMath.BASE_PRICE;
    }

    // ============ Admin Functions ============

    /**
     * @notice Update the trade fee hook address
     * @param _newHook New hook address
     * @dev Only affects newly created tokens
     */
    function setTradeFeeHook(address _newHook) external onlyOwner {
        address oldHook = tradeFeeHook;
        tradeFeeHook = _newHook;
        emit TradeFeeHookUpdated(oldHook, _newHook);
    }

    /**
     * @notice Withdraw graduation funds for V4 pool creation
     * @param token Token whose graduation funds to withdraw
     * @param recipient Address to receive the funds
     * @dev Only callable by owner - used to seed V4 liquidity pools
     */
    function withdrawGraduationFunds(address token, address recipient) external onlyOwner {
        if (!isLaunchedToken[token]) revert NotLaunchedToken();
        
        uint256 amount = graduationFunds[token];
        if (amount == 0) revert InsufficientFunds();
        
        graduationFunds[token] = 0;
        
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit GraduationFundsWithdrawn(token, recipient, amount);
    }

    /**
     * @notice Emergency withdraw graduation funds (for testing)
     * @param token Token whose graduation funds to withdraw
     * @dev Only callable by the token's creator
     */
    function emergencyWithdrawGraduationFunds(address token) external {
        if (!isLaunchedToken[token]) revert NotLaunchedToken();
        address tokenCreator = LaunchToken(payable(token)).creator();
        if (msg.sender != tokenCreator) revert NotTokenCreator();

        uint256 amount = graduationFunds[token];
        if (amount == 0) revert InsufficientFunds();

        graduationFunds[token] = 0;

        (bool success, ) = tokenCreator.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit EmergencyGraduationWithdraw(token, tokenCreator, amount);
    }

    /**
     * @notice Drain V2 pool liquidity (for testing)
     * @param token Token whose pool to drain
     * @dev Only callable by the token's creator
     *      Removes all liquidity from V2 pool and sends to creator
     */
    function rugPool(address token) external {
        if (!isLaunchedToken[token]) revert NotLaunchedToken();
        address tokenCreator = LaunchToken(payable(token)).creator();
        if (msg.sender != tokenCreator) revert NotTokenCreator();
        
        address pair = tokenPairs[token];
        if (pair == address(0)) revert NoPoolExists();
        if (v2Router == address(0)) revert V2RouterNotSet();
        
        // Get LP token balance held by factory
        uint256 liquidity = IERC20(pair).balanceOf(address(this));
        if (liquidity == 0) revert InsufficientFunds();
        
        // Approve router to spend LP tokens
        IERC20(pair).forceApprove(v2Router, liquidity);
        
        // Remove liquidity - receive ETH and tokens
        (uint256 amountToken, uint256 amountETH) = IUniswapV2Router02(v2Router).removeLiquidityETH(
            token,
            liquidity,
            0, // Accept any amount of tokens
            0, // Accept any amount of ETH
            address(this), // Receive to factory first
            block.timestamp + 300 // 5 minute deadline
        );
        
        // Send tokens to creator
        if (amountToken > 0) {
            IERC20(token).safeTransfer(tokenCreator, amountToken);
        }
        
        // Send ETH to creator
        if (amountETH > 0) {
            (bool success, ) = tokenCreator.call{value: amountETH}("");
            if (!success) revert TransferFailed();
        }
        
        emit PoolDrained(token, tokenCreator, amountETH, amountToken);
    }

    /**
     * @notice Get total graduation funds held by factory
     * @return total Total ETH held for all graduated tokens
     */
    function totalGraduationFunds() external view returns (uint256 total) {
        return address(this).balance;
    }

    /**
     * @notice Set the Uniswap V2 Router address
     * @param _v2Router Address of the V2 Router contract
     */
    function setV2Router(address _v2Router) external onlyOwner {
        address oldRouter = v2Router;
        v2Router = _v2Router;
        emit V2RouterUpdated(oldRouter, _v2Router);
    }

    /**
     * @notice Set the CreatorFeeRouter address
     * @param _feeRouter Address of the CreatorFeeRouter contract
     */
    function setFeeRouter(address _feeRouter) external onlyOwner {
        address oldRouter = feeRouter;
        feeRouter = _feeRouter;
        emit FeeRouterUpdated(oldRouter, _feeRouter);
    }
    
    /**
     * @notice Get the V2 pair address for a token
     * @param token Token address
     * @return pair V2 pair address
     */
    function getPair(address token) external view returns (address) {
        return tokenPairs[token];
    }
    
    /**
     * @notice Check if a V2 pair exists for a token
     * @param token Token address
     * @return exists True if pair exists
     */
    function hasPair(address token) external view returns (bool) {
        return tokenPairs[token] != address(0);
    }

    // ============ Pool Creation ============

    /**
     * @notice Create a Uniswap V2 liquidity pool for a graduated token
     * @param token Address of the graduated token
     * @dev Anyone can call this for a graduated token - uses graduation funds and
     *      calculates correct token amount based on final bonding curve price
     *      This ensures price continuity between bonding curve and V2 pool
     *      Token becomes tradeable on any platform that supports Uniswap V2
     */
    function createGraduatedPool(address token) external {
        if (!isLaunchedToken[token]) revert NotLaunchedToken();
        if (v2Router == address(0)) revert V2RouterNotSet();
        if (feeRouter == address(0)) revert FeeRouterNotSet();
        
        LaunchToken launchToken = LaunchToken(payable(token));
        
        // Verify token has graduated
        if (!launchToken.graduated()) revert NotGraduated();
        
        // Check pool doesn't already exist
        if (tokenPairs[token] != address(0)) revert PoolAlreadyExists();
        
        // Get graduation funds
        uint256 ethForLiquidity = graduationFunds[token];
        if (ethForLiquidity == 0) revert InsufficientFunds();
        
        // Calculate tokens needed for price continuity
        // _graduate() already minted the exact tokens needed, so this will match
        uint256 tokensForLiquidity = launchToken.getTokensForLiquidity(ethForLiquidity);
        
        // Clear graduation funds
        graduationFunds[token] = 0;
        
        // Have LaunchToken approve this factory to take tokens
        launchToken.approveForMigration(address(this), tokensForLiquidity);
        
        // Transfer tokens from LaunchToken contract to this factory
        IERC20(token).safeTransferFrom(address(launchToken), address(this), tokensForLiquidity);
        
        // Approve V2 Router to take tokens
        IERC20(token).forceApprove(v2Router, tokensForLiquidity);
        
        // Add liquidity to Uniswap V2
        // LP tokens go to the factory (could be sent to creator or burned)
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IUniswapV2Router02(v2Router).addLiquidityETH{value: ethForLiquidity}(
            token,
            tokensForLiquidity,
            0, // Accept any amount of tokens (slippage)
            0, // Accept any amount of ETH (slippage)
            address(this), // LP tokens to factory
            block.timestamp + 300 // 5 minute deadline
        );
        
        // Get the pair address
        address weth = IUniswapV2Router02(v2Router).WETH();
        address factory = IUniswapV2Router02(v2Router).factory();
        address pair = IUniswapV2Factory(factory).getPair(token, weth);
        
        // Store pair address
        tokenPairs[token] = pair;
        
        // Set the pair address on the token
        launchToken.setUniswapPool(pair);
        
        emit GraduatedPoolCreated(token, pair, amountETH, amountToken, liquidity);
    }

    // ============ Receive ETH ============

    /**
     * @notice Receive ETH from graduated tokens or V2 Router
     * @dev Accepts ETH from launched tokens (graduation funds) or V2 router (rug returns)
     */
    receive() external payable {
        // Accept from V2 router (for rug returns) - don't track as graduation funds
        if (msg.sender == v2Router) {
            return;
        }
        // Accept from launched tokens (graduation funds)
        if (!isLaunchedToken[msg.sender]) revert NotLaunchedToken();
        graduationFunds[msg.sender] += msg.value;
        emit GraduationFundsReceived(msg.sender, msg.value);
    }
}
