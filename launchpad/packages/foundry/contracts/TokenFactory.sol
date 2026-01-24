// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./LaunchToken.sol";

/**
 * @title TokenFactory
 * @notice Factory for deploying LaunchToken instances using ERC-1167 minimal proxy pattern
 * @dev Each token deployment costs ~45 bytes instead of full contract bytecode
 *      Handles graduation funds from tokens for V4 pool creation
 */
contract TokenFactory is Ownable {
    using Clones for address;

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

    // ============ Errors ============

    error EmptyName();
    error EmptySymbol();
    error InvalidHook();
    error NotLaunchedToken();
    error InsufficientFunds();
    error TransferFailed();

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
     * @notice Get total graduation funds held by factory
     * @return total Total ETH held for all graduated tokens
     */
    function totalGraduationFunds() external view returns (uint256 total) {
        return address(this).balance;
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
