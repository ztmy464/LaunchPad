// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./TradeFeeHook.sol";
import "./LaunchToken.sol";

/**
 * @title GraduationManager
 * @notice Handles graduation of LaunchTokens to Uniswap V4 pools
 * @dev Creates V4 pools and adds initial liquidity when tokens graduate
 */
contract GraduationManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    // ============ Events ============

    event TokenGraduated(
        address indexed token,
        PoolId indexed poolId,
        uint256 ethLiquidity,
        uint256 tokenLiquidity
    );

    // ============ Errors ============

    error Unauthorized();
    error AlreadyGraduated();
    error NotGraduated();
    error InsufficientLiquidity();

    // ============ State ============

    /// @notice Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice Uniswap V4 PositionManager for adding liquidity
    address public immutable positionManager;

    /// @notice TradeFeeHook for fee collection
    address payable public immutable tradeFeeHook;

    /// @notice Authorized factory
    address public factory;

    /// @notice Owner for admin functions
    address public owner;

    /// @notice Mapping from token to its V4 pool key
    mapping(address => PoolKey) public tokenPoolKeys;

    /// @notice Mapping from token to whether it has a V4 pool
    mapping(address => bool) public hasPool;

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        address _positionManager,
        address payable _tradeFeeHook
    ) {
        poolManager = _poolManager;
        positionManager = _positionManager;
        tradeFeeHook = _tradeFeeHook;
        owner = msg.sender;
    }

    // ============ Admin ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    function setFactory(address _factory) external onlyOwner {
        factory = _factory;
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
    }

    // ============ Graduation ============

    /**
     * @notice Graduate a token to Uniswap V4
     * @param token The LaunchToken address
     * @param ethAmount ETH to add as liquidity
     * @param tokenAmount Tokens to add as liquidity
     * @dev Called by the token when graduation threshold is reached
     */
    function graduate(
        address token,
        uint256 ethAmount,
        uint256 tokenAmount
    ) external payable returns (PoolKey memory poolKey, PoolId poolId) {
        // Only the token itself can call this
        if (msg.sender != token) revert Unauthorized();
        if (hasPool[token]) revert AlreadyGraduated();
        if (msg.value < ethAmount) revert InsufficientLiquidity();

        // Create pool key
        // currency0 should be the lower address (ETH = address(0))
        Currency currency0 = CurrencyLibrary.ADDRESS_ZERO; // ETH
        Currency currency1 = Currency.wrap(token);

        // Ensure correct ordering (currency0 < currency1)
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.3% base fee (hook adds directional fees)
            tickSpacing: 60, // Standard for 0.3% pools
            hooks: IHooks(tradeFeeHook)
        });

        poolId = poolKey.toId();

        // Initialize the pool at a reasonable price
        // sqrtPriceX96 = sqrt(price) * 2^96
        // For starting price of ~0.0002 ETH per token:
        // price = 0.0002, sqrt(0.0002) ≈ 0.01414
        // sqrtPriceX96 = 0.01414 * 2^96 ≈ 1.12e27
        uint160 sqrtPriceX96 = 1120000000000000000000000000; // ~0.0002 ETH/token

        // Initialize pool
        poolManager.initialize(poolKey, sqrtPriceX96);

        // Register pool with hook for fee collection
        TradeFeeHook(tradeFeeHook).registerPool(poolKey, token, token);

        // Store pool info
        tokenPoolKeys[token] = poolKey;
        hasPool[token] = true;

        // Add initial liquidity
        _addLiquidity(poolKey, ethAmount, tokenAmount, token);

        emit TokenGraduated(token, poolId, ethAmount, tokenAmount);

        return (poolKey, poolId);
    }

    /**
     * @notice Add liquidity to a V4 pool
     * @dev Uses PositionManager to add liquidity
     */
    function _addLiquidity(
        PoolKey memory poolKey,
        uint256 ethAmount,
        uint256 tokenAmount,
        address token
    ) internal {
        // Approve token to PositionManager
        IERC20(token).approve(positionManager, tokenAmount);

        // Calculate tick range for full-range liquidity
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        // Encode the mint action
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        // Encode parameters for MINT_POSITION
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint128(ethAmount), // liquidity amount (simplified)
            type(uint128).max, // amount0Max
            type(uint128).max, // amount1Max
            address(this), // recipient
            "" // hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        // Execute via PositionManager
        IPositionManager(positionManager).modifyLiquidities{value: ethAmount}(
            abi.encode(actions, params),
            block.timestamp + 60
        );
    }

    // ============ View Functions ============

    /**
     * @notice Get pool key for a graduated token
     * @param token Token address
     * @return poolKey The V4 pool key
     */
    function getPoolKey(address token) external view returns (PoolKey memory) {
        require(hasPool[token], "Token not graduated");
        return tokenPoolKeys[token];
    }

    /**
     * @notice Check if a token has graduated to V4
     * @param token Token address
     * @return bool Whether token has a V4 pool
     */
    function isGraduated(address token) external view returns (bool) {
        return hasPool[token];
    }

    // ============ Receive ETH ============

    receive() external payable {}
}
