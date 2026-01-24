// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./LaunchToken.sol";
import "./SimplePool.sol";
import "./libraries/BondingCurveMath.sol";

/**
 * @title TokenFactory
 * @notice Factory for deploying LaunchToken instances using ERC-1167 minimal proxy pattern
 * @dev Each token deployment costs ~45 bytes instead of full contract bytecode
 *      Handles graduation funds from tokens for V4 pool creation
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
    
    event GraduatedPoolCreated(address indexed token, address indexed pool, uint256 ethAmount, uint256 tokenAmount);
    
    event SimplePoolUpdated(address indexed oldPool, address indexed newPool);
    event EmergencyGraduationWithdraw(address indexed token, address indexed creator, uint256 amount);

    // ============ Errors ============

    error EmptyName();
    error EmptySymbol();
    error InvalidHook();
    error NotLaunchedToken();
    error InsufficientFunds();
    error TransferFailed();
    error NotGraduated();
    error PoolAlreadyExists();
    error SimplePoolNotSet();
    error NotTokenCreator();

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
    
    /// @notice SimplePool contract for graduated token trading
    address public simplePool;

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

        // Clone the implementation (creates minimal proxy)
        token = tokenImplementation.clone();

        // Initialize the clone
        LaunchToken(payable(token)).initialize(
            name,
            symbol,
            msg.sender,
            tradeFeeHook
        );

        // Track the token
        launchedTokens.push(token);
        isLaunchedToken[token] = true;
        tokensByCreator[msg.sender].push(token);

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

        // Clone with deterministic address
        token = tokenImplementation.cloneDeterministic(salt);

        // Initialize the clone
        LaunchToken(payable(token)).initialize(
            name,
            symbol,
            msg.sender,
            tradeFeeHook
        );

        // Track the token
        launchedTokens.push(token);
        isLaunchedToken[token] = true;
        tokensByCreator[msg.sender].push(token);

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
     * @notice Get total graduation funds held by factory
     * @return total Total ETH held for all graduated tokens
     */
    function totalGraduationFunds() external view returns (uint256 total) {
        return address(this).balance;
    }

    /**
     * @notice Set the SimplePool contract address
     * @param _simplePool Address of the SimplePool contract
     */
    function setSimplePool(address _simplePool) external onlyOwner {
        address oldPool = simplePool;
        simplePool = _simplePool;
        emit SimplePoolUpdated(oldPool, _simplePool);
    }

    // ============ Pool Creation ============

    /**
     * @notice Create a liquidity pool for a graduated token using stored graduation funds
     * @param token Address of the graduated token
     * @dev Anyone can call this for a graduated token - uses graduation funds and
     *      calculates correct token amount based on final bonding curve price
     *      This ensures price continuity between bonding curve and pool
     */
    function createGraduatedPool(address token) external {
        if (!isLaunchedToken[token]) revert NotLaunchedToken();
        if (simplePool == address(0)) revert SimplePoolNotSet();
        
        LaunchToken launchToken = LaunchToken(payable(token));
        
        // Verify token has graduated
        if (!launchToken.graduated()) revert NotGraduated();
        
        // Check pool doesn't already exist
        if (SimplePool(payable(simplePool)).hasPool(token)) revert PoolAlreadyExists();
        
        // Get graduation funds
        uint256 ethForLiquidity = graduationFunds[token];
        if (ethForLiquidity == 0) revert InsufficientFunds();
        
        // Calculate tokens needed for price continuity
        uint256 tokensForLiquidity = launchToken.getTokensForLiquidity(ethForLiquidity);
        
        // Get tokens held by the LaunchToken contract (minted during graduation)
        uint256 availableTokens = launchToken.getContractTokenBalance();
        if (availableTokens < tokensForLiquidity) {
            // Use whatever tokens are available if not enough
            tokensForLiquidity = availableTokens;
        }
        
        // Clear graduation funds
        graduationFunds[token] = 0;
        
        // Have LaunchToken approve this factory to take tokens
        launchToken.approveForMigration(address(this), tokensForLiquidity);
        
        // Transfer tokens from LaunchToken contract to this factory
        IERC20(token).safeTransferFrom(address(launchToken), address(this), tokensForLiquidity);
        
        // Approve SimplePool to take tokens from this factory
        IERC20(token).forceApprove(simplePool, tokensForLiquidity);
        
        // Get the original token creator for emergency drain rights
        address tokenCreator = launchToken.creator();
        
        // Create the pool with graduation funds and tokens, passing original creator
        SimplePool(payable(simplePool)).createPoolWithCreator{value: ethForLiquidity}(token, tokensForLiquidity, tokenCreator);
        
        // Set the pool address on the token
        launchToken.setUniswapPool(simplePool);
        
        emit GraduatedPoolCreated(token, simplePool, ethForLiquidity, tokensForLiquidity);
    }

    // ============ Receive ETH ============

    /**
     * @notice Receive ETH from graduated tokens
     * @dev Only accepts ETH from launched tokens (graduation funds)
     */
    receive() external payable {
        if (!isLaunchedToken[msg.sender]) revert NotLaunchedToken();
        graduationFunds[msg.sender] += msg.value;
        emit GraduationFundsReceived(msg.sender, msg.value);
    }
}
