// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./libraries/BondingCurveMath.sol";

/**
 * @title LaunchToken
 * @notice ERC20 token with bonding curve for initial liquidity bootstrapping
 * @dev Uses ERC-1167 minimal proxy pattern - deployed via TokenFactory
 */
contract LaunchToken is Initializable, ERC20Upgradeable {
    using BondingCurveMath for uint256;

    // ============ Reentrancy Guard ============
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status;

    modifier nonReentrant() {
        require(_status != ENTERED, "ReentrancyGuard: reentrant call");
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    // ============ Events ============

    event TokensBought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 fee);
    event TokensSold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 fee);
    event Graduated(address indexed pool, uint256 ethLiquidity, uint256 tokenLiquidity);
    event TreasuryWithdrawn(address indexed creator, uint256 amount);
    event EmergencyWithdraw(address indexed creator, uint256 ethAmount, uint256 tokenAmount);

    // ============ Errors ============

    error AlreadyGraduated();
    error NotGraduated();
    error InsufficientPayment();
    error InsufficientTokens();
    error TransferFailed();
    error ZeroAmount();
    error CooldownActive();
    error OnlyCreator();

    // ============ State Variables ============

    /// @notice Address of the token creator
    address public creator;

    /// @notice Factory that deployed this token
    address public factory;

    /// @notice Timestamp when token was launched (for cooldown)
    uint256 public launchTime;

    /// @notice ETH accumulated as creator earnings (from fees) - withdrawable by creator
    uint256 public treasury;

    /// @notice Whether token has graduated to Uniswap
    bool public graduated;

    /// @notice Reference to the V4 trade fee hook
    address public tradeFeeHook;

    /// @notice Reference to the graduation manager
    address public graduationManager;

    /// @notice Uniswap V4 pool address after graduation
    address public uniswapPool;

    /// @notice Reserve balance for bonding curve (ETH held for sells)
    uint256 public reserveBalance;

    // ============ Initialization ============

    /// @notice Initialize the token (called by factory via proxy)
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _creator Address of the token creator
    /// @param _tradeFeeHook Address of the V4 trade fee hook
    function initialize(
        string memory _name,
        string memory _symbol,
        address _creator,
        address _tradeFeeHook
    ) external initializer {
        __ERC20_init(_name, _symbol);
        _status = NOT_ENTERED;

        creator = _creator;
        factory = msg.sender;
        launchTime = block.timestamp;
        tradeFeeHook = _tradeFeeHook;
    }

    // ============ Buy/Sell Functions ============

    /**
     * @notice Buy tokens with ETH
     * @dev Applies cooldown penalty and buy fee
     */
    function buy() external payable nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (msg.value == 0) revert ZeroAmount();

        // Calculate buy fee (1%)
        uint256 fee = BondingCurveMath.calculateBuyFee(msg.value);
        uint256 ethForTokens = msg.value - fee;

        // Add fee to treasury
        treasury += fee;

        // Calculate tokens to mint based on bonding curve
        uint256 currentSupply = totalSupply();
        uint256 tokensToMint = BondingCurveMath.calculateTokensForETH(currentSupply, ethForTokens);

        if (tokensToMint == 0) revert ZeroAmount();

        // Apply cooldown penalty (sniper protection)
        uint256 adjustedTokens = BondingCurveMath.applyCooldownPenalty(tokensToMint, launchTime);

        // The "lost" tokens due to cooldown go to increasing the reserve
        // This makes early snipers subsidize later buyers
        uint256 cooldownPenalty = tokensToMint - adjustedTokens;

        // Add ETH to reserve (for future sells)
        reserveBalance += ethForTokens;

        // Mint tokens to buyer
        _mint(msg.sender, adjustedTokens);

        // If cooldown penalty, mint those tokens to treasury (locked)
        // These can be used for liquidity or burned
        if (cooldownPenalty > 0) {
            _mint(address(this), cooldownPenalty);
        }

        emit TokensBought(msg.sender, msg.value, adjustedTokens, fee);

        // Check for graduation
        _checkGraduation();
    }

    /**
     * @notice Sell tokens for ETH
     * @param tokensToSell Amount of tokens to sell
     * @dev Applies sell fee (2%)
     */
    function sell(uint256 tokensToSell) external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (tokensToSell == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < tokensToSell) revert InsufficientTokens();

        // Calculate ETH to return based on bonding curve
        uint256 currentSupply = totalSupply();
        uint256 ethToReturn = BondingCurveMath.calculateSellReturn(currentSupply, tokensToSell);

        // Ensure we have enough reserve
        if (ethToReturn > reserveBalance) {
            ethToReturn = reserveBalance;
        }

        // Calculate sell fee (2%)
        uint256 fee = BondingCurveMath.calculateSellFee(ethToReturn);
        uint256 ethAfterFee = ethToReturn - fee;

        // Add fee to treasury
        treasury += fee;

        // Reduce reserve
        reserveBalance -= ethToReturn;

        // Burn tokens
        _burn(msg.sender, tokensToSell);

        // Send ETH to seller
        (bool success, ) = msg.sender.call{value: ethAfterFee}("");
        if (!success) revert TransferFailed();

        emit TokensSold(msg.sender, tokensToSell, ethAfterFee, fee);
    }

    // ============ View Functions ============

    /**
     * @notice Get current price per token
     * @return price Current price in wei
     */
    function getCurrentPrice() external view returns (uint256) {
        return BondingCurveMath.getCurrentPrice(totalSupply());
    }

    /**
     * @notice Estimate tokens received for a given ETH amount
     * @param ethAmount ETH to spend
     * @return tokens Estimated tokens (after fees and cooldown)
     */
    function estimateBuy(uint256 ethAmount) external view returns (uint256) {
        uint256 fee = BondingCurveMath.calculateBuyFee(ethAmount);
        uint256 ethForTokens = ethAmount - fee;
        uint256 tokens = BondingCurveMath.calculateTokensForETH(totalSupply(), ethForTokens);
        return BondingCurveMath.applyCooldownPenalty(tokens, launchTime);
    }

    /**
     * @notice Estimate ETH received for selling tokens
     * @param tokensToSell Tokens to sell
     * @return ethAmount Estimated ETH (after fees)
     */
    function estimateSell(uint256 tokensToSell) external view returns (uint256) {
        uint256 ethReturn = BondingCurveMath.calculateSellReturn(totalSupply(), tokensToSell);
        if (ethReturn > reserveBalance) {
            ethReturn = reserveBalance;
        }
        uint256 fee = BondingCurveMath.calculateSellFee(ethReturn);
        return ethReturn - fee;
    }

    /**
     * @notice Check if cooldown period has passed
     * @return bool True if cooldown is complete
     */
    function isCooldownComplete() external view returns (bool) {
        return block.timestamp >= launchTime + BondingCurveMath.COOLDOWN_PERIOD;
    }

    /**
     * @notice Get time remaining in cooldown
     * @return seconds Seconds remaining (0 if complete)
     */
    function cooldownRemaining() external view returns (uint256) {
        uint256 endTime = launchTime + BondingCurveMath.COOLDOWN_PERIOD;
        if (block.timestamp >= endTime) return 0;
        return endTime - block.timestamp;
    }

    /**
     * @notice Get progress towards graduation threshold
     * @return progress Percentage (0-100) of graduation threshold reached
     * @dev Based on reserveBalance, not treasury
     */
    function graduationProgress() external view returns (uint256) {
        if (graduated) return 100;
        return (reserveBalance * 100) / BondingCurveMath.GRADUATION_THRESHOLD;
    }

    /**
     * @notice Get the tokens needed for liquidity at current price
     * @param ethAmount Amount of ETH for liquidity
     * @return tokensNeeded Number of tokens needed to match the current bonding curve price
     * @dev Used by factory to calculate correct pool initialization amounts
     */
    function getTokensForLiquidity(uint256 ethAmount) external view returns (uint256) {
        uint256 currentPrice = BondingCurveMath.getCurrentPrice(totalSupply());
        return (ethAmount * 1e18) / currentPrice;
    }

    // ============ Internal Functions ============

    /**
     * @notice Check if reserve balance threshold is met and trigger graduation
     */
    function _checkGraduation() internal {
        if (reserveBalance >= BondingCurveMath.GRADUATION_THRESHOLD && !graduated) {
            _graduate();
        }
    }

    /**
     * @notice Graduate to Uniswap V4
     * @dev Transfers reserveBalance to factory for V4 pool creation
     *      Treasury (creator earnings) is NOT touched - creator can withdraw separately
     *      Calculates tokens for liquidity based on final bonding curve price for price continuity
     */
    function _graduate() internal {
        graduated = true;

        // Use reserveBalance for V4 liquidity (NOT treasury - that's creator earnings)
        uint256 ethForLiquidity = reserveBalance;
        reserveBalance = 0;

        // Calculate tokens for liquidity based on final bonding curve price
        // This ensures price continuity: pool price = ethForLiquidity / tokensForLiquidity = finalPrice
        uint256 finalPrice = BondingCurveMath.getCurrentPrice(totalSupply());
        uint256 tokensForLiquidity = (ethForLiquidity * 1e18) / finalPrice;

        // Mint tokens for liquidity (to this contract, factory will transfer them)
        uint256 contractTokens = balanceOf(address(this));
        if (contractTokens < tokensForLiquidity) {
            _mint(address(this), tokensForLiquidity - contractTokens);
        }

        // Transfer ETH to factory for V4 pool creation
        // The factory holds funds until V4 pool is created
        (bool success, ) = factory.call{value: ethForLiquidity}("");
        require(success, "ETH transfer to factory failed");

        emit Graduated(factory, ethForLiquidity, tokensForLiquidity);
    }

    // ============ Migration Functions ============

    /**
     * @notice Complete migration to Uniswap V4 (called by factory)
     * @param _pool Address of the created V4 pool
     */
    function setUniswapPool(address _pool) external {
        require(msg.sender == factory, "Only factory");
        require(graduated, "Not graduated");
        uniswapPool = _pool;
    }

    /**
     * @notice Get tokens held by contract for liquidity
     */
    function getContractTokenBalance() external view returns (uint256) {
        return balanceOf(address(this));
    }

    /**
     * @notice Approve tokens for migration (called by factory)
     * @param spender Address to approve
     * @param amount Amount to approve
     */
    function approveForMigration(address spender, uint256 amount) external {
        require(msg.sender == factory, "Only factory");
        _approve(address(this), spender, amount);
    }

    // ============ Creator Functions ============

    /**
     * @notice Withdraw accumulated treasury (creator earnings from fees)
     * @dev Only callable by the token creator
     */
    function withdrawTreasury() external nonReentrant {
        if (msg.sender != creator) revert OnlyCreator();
        
        uint256 amount = treasury;
        if (amount == 0) revert ZeroAmount();
        
        treasury = 0;
        
        (bool success, ) = creator.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit TreasuryWithdrawn(creator, amount);
    }

    /**
     * @notice Emergency withdraw all funds (for testing)
     * @dev Drains bonding curve reserve and treasury to creator
     */
    function emergencyWithdraw() external nonReentrant {
        if (msg.sender != creator) revert OnlyCreator();

        uint256 ethAmount = reserveBalance + treasury;
        uint256 tokenAmount = balanceOf(address(this));

        reserveBalance = 0;
        treasury = 0;

        if (tokenAmount > 0) {
            _transfer(address(this), creator, tokenAmount);
        }

        if (ethAmount > 0) {
            (bool success, ) = creator.call{value: ethAmount}("");
            if (!success) revert TransferFailed();
        }

        emit EmergencyWithdraw(creator, ethAmount, tokenAmount);
    }

    // ============ Receive ETH ============

    receive() external payable {
        // Accept ETH for buys
    }
}
