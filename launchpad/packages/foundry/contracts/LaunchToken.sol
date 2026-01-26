// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./libraries/BondingCurveMath.sol";

/**
 * @title ICreatorFeeRouter
 * @notice Interface for depositing fees to the CreatorFeeRouter
 */
interface ICreatorFeeRouter {
    function depositFees(address token) external payable;
}

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
    error InsufficientReserve();
    error TransferFailed();
    error ZeroAmount();
    error CooldownActive();
    error OnlyCreator();
    error TransferToPoolBlocked();

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

    /// @notice CreatorFeeRouter address for forwarding fees
    address public feeRouter;

    /// @notice Tokens minted for liquidity during graduation (stored for factory to use)
    uint256 public mintedForLiquidity;

    /// @notice Pre-computed V2 pair address (transfers blocked until graduation)
    address public expectedV2Pair;

    // ============ Initialization ============

    /// @notice Initialize the token (called by factory via proxy)
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _creator Address of the token creator
    /// @param _tradeFeeHook Address of the V4 trade fee hook
    /// @param _v2Factory Uniswap V2 Factory address for computing pair address
    /// @param _weth WETH address for computing pair address
    function initialize(
        string memory _name,
        string memory _symbol,
        address _creator,
        address _tradeFeeHook,
        address _v2Factory,
        address _weth
    ) external initializer {
        __ERC20_init(_name, _symbol);
        _status = NOT_ENTERED;

        creator = _creator;
        factory = msg.sender;
        launchTime = block.timestamp;
        tradeFeeHook = _tradeFeeHook;
        
        // Compute and store expected V2 pair address to block transfers until graduation
        expectedV2Pair = _computePairAddress(_v2Factory, address(this), _weth);
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

        // Forward fee to CreatorFeeRouter if set, otherwise add to local treasury
        if (feeRouter != address(0)) {
            ICreatorFeeRouter(feeRouter).depositFees{value: fee}(address(this));
        } else {
            treasury += fee;
        }

        // Calculate tokens to mint based on bonding curve
        uint256 currentSupply = totalSupply();
        uint256 tokensToMint = BondingCurveMath.calculateTokensForETH(currentSupply, ethForTokens);

        if (tokensToMint == 0) revert ZeroAmount();

        // Apply cooldown penalty (sniper protection)
        // During cooldown, buyer receives fewer tokens but supply reflects only what they receive
        uint256 adjustedTokens = BondingCurveMath.applyCooldownPenalty(tokensToMint, launchTime);

        // Add ETH to reserve (for future sells)
        reserveBalance += ethForTokens;

        // Mint only the adjusted tokens to buyer - no phantom tokens
        _mint(msg.sender, adjustedTokens);

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

        // Ensure we have enough reserve - revert if not
        if (ethToReturn > reserveBalance) revert InsufficientReserve();

        // Calculate sell fee (2%)
        uint256 fee = BondingCurveMath.calculateSellFee(ethToReturn);
        uint256 ethAfterFee = ethToReturn - fee;

        // Forward fee to CreatorFeeRouter if set, otherwise add to local treasury
        if (feeRouter != address(0)) {
            ICreatorFeeRouter(feeRouter).depositFees{value: fee}(address(this));
        } else {
            treasury += fee;
        }

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
     * @return ethAmount Estimated ETH (after fees), returns 0 if reserve insufficient
     */
    function estimateSell(uint256 tokensToSell) external view returns (uint256) {
        uint256 ethReturn = BondingCurveMath.calculateSellReturn(totalSupply(), tokensToSell);
        // Return 0 if reserve is insufficient (actual sell will revert)
        if (ethReturn > reserveBalance) {
            return 0;
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
     * @notice Get the tokens minted for liquidity during graduation
     * @return tokensNeeded Number of tokens minted for pool liquidity
     * @dev Returns the stored amount calculated before minting to ensure correct supply is used
     */
    function getTokensForLiquidity(uint256) external view returns (uint256) {
        // Return the stored amount that was calculated and minted during graduation
        // This avoids recalculating with incorrect (post-mint) supply
        return mintedForLiquidity;
    }

    // ============ Internal Functions ============

    /**
     * @notice Override transfer to block sends to V2 pair until graduated
     * @dev This prevents front-running attacks where someone creates the V2 pair
     *      with a bad ratio before the official pool creation
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Block transfers to V2 pair until graduated
        if (to == expectedV2Pair && !graduated) {
            revert TransferToPoolBlocked();
        }
        super._update(from, to, amount);
    }

    /**
     * @notice Compute deterministic V2 pair address (Uniswap V2 uses CREATE2)
     * @param _factory V2 Factory address
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return pair The deterministic pair address
     */
    function _computePairAddress(
        address _factory,
        address tokenA,
        address tokenB
    ) internal pure returns (address pair) {
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff",
            _factory,
            keccak256(abi.encodePacked(token0, token1)),
            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f" // Uniswap V2 init code hash
        )))));
    }

    /**
     * @notice Check if reserve balance threshold is met and trigger graduation
     */
    function _checkGraduation() internal {
        if (reserveBalance >= BondingCurveMath.GRADUATION_THRESHOLD && !graduated) {
            _graduate();
        }
    }

    /**
     * @notice Graduate to Uniswap V2 pool
     * @dev Transfers reserveBalance to factory for pool creation
     *      Treasury (creator earnings) is NOT touched - creator can withdraw separately
     *      Calculates tokens so first pool trade matches last bonding curve trade
     */
    function _graduate() internal {
        graduated = true;

        // Use ALL reserveBalance for pool liquidity (treasury is separate - creator earnings)
        uint256 ethForLiquidity = reserveBalance;
        reserveBalance = 0;

        // Calculate tokens so first pool trade matches last bonding curve trade
        // This uses a reference trade size to ensure effective price continuity
        // IMPORTANT: Calculate BEFORE minting to use correct supply
        uint256 tokensForLiquidity = BondingCurveMath.calculatePoolTokens(totalSupply(), ethForLiquidity);

        // Store the calculated amount for factory to retrieve
        mintedForLiquidity = tokensForLiquidity;

        // Mint tokens needed for liquidity
        _mint(address(this), tokensForLiquidity);

        // Transfer ETH to factory - factory will create the V2 pool
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

    /**
     * @notice Set the fee router address (called by factory)
     * @param _feeRouter Address of the CreatorFeeRouter
     */
    function setFeeRouter(address _feeRouter) external {
        require(msg.sender == factory, "Only factory");
        feeRouter = _feeRouter;
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
     * @dev Drains ALL ETH (including any stuck ETH) and tokens to creator
     */
    function emergencyWithdraw() external nonReentrant {
        if (msg.sender != creator) revert OnlyCreator();

        // Use actual balance to recover any stuck ETH sent directly to contract
        uint256 ethAmount = address(this).balance;
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
