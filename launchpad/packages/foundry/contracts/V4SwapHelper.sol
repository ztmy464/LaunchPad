// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title V4SwapHelper
 * @notice Simple swap helper for graduated LaunchTokens on Uniswap V4
 * @dev Provides easy-to-use swap functions for ETH <-> Token trades
 */
contract V4SwapHelper is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    // ============ Structs ============

    struct SwapCallbackData {
        address sender;
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
    }

    // ============ Events ============

    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    // ============ Errors ============

    error InvalidPool();
    error InsufficientOutput();
    error TransferFailed();

    // ============ State ============

    IPoolManager public immutable poolManager;

    /// @notice Registered pools (token => PoolKey)
    mapping(address => PoolKey) public tokenPools;
    mapping(address => bool) public hasPool;

    // ============ Constructor ============

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ============ Pool Registration ============

    /**
     * @notice Register a token's V4 pool
     * @param token Token address
     * @param key Pool key
     */
    function registerPool(address token, PoolKey calldata key) external {
        tokenPools[token] = key;
        hasPool[token] = true;
    }

    // ============ Swap Functions ============

    /**
     * @notice Swap ETH for tokens
     * @param token Token to buy
     * @param minTokensOut Minimum tokens to receive
     * @return tokensOut Actual tokens received
     */
    function swapETHForTokens(
        address token,
        uint256 minTokensOut
    ) external payable returns (uint256 tokensOut) {
        if (!hasPool[token]) revert InvalidPool();
        
        PoolKey memory key = tokenPools[token];
        
        // ETH -> Token: zeroForOne depends on ordering
        bool zeroForOne = Currency.unwrap(key.currency0) == address(0);
        
        // Exact input swap (negative amount = exact input)
        int256 amountSpecified = -int256(msg.value);
        
        SwapCallbackData memory data = SwapCallbackData({
            sender: msg.sender,
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified
        });
        
        // Execute swap via unlock
        bytes memory result = poolManager.unlock(abi.encode(data));
        tokensOut = abi.decode(result, (uint256));
        
        if (tokensOut < minTokensOut) revert InsufficientOutput();
        
        emit Swap(msg.sender, address(0), token, msg.value, tokensOut);
    }

    /**
     * @notice Swap tokens for ETH
     * @param token Token to sell
     * @param tokenAmount Tokens to sell
     * @param minETHOut Minimum ETH to receive
     * @return ethOut Actual ETH received
     */
    function swapTokensForETH(
        address token,
        uint256 tokenAmount,
        uint256 minETHOut
    ) external returns (uint256 ethOut) {
        if (!hasPool[token]) revert InvalidPool();
        
        // Transfer tokens from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        
        PoolKey memory key = tokenPools[token];
        
        // Token -> ETH: opposite of zeroForOne for ETH->Token
        bool zeroForOne = Currency.unwrap(key.currency0) != address(0);
        
        // Exact input swap
        int256 amountSpecified = -int256(tokenAmount);
        
        SwapCallbackData memory data = SwapCallbackData({
            sender: msg.sender,
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified
        });
        
        // Execute swap via unlock
        bytes memory result = poolManager.unlock(abi.encode(data));
        ethOut = abi.decode(result, (uint256));
        
        if (ethOut < minETHOut) revert InsufficientOutput();
        
        // Transfer ETH to sender
        (bool success, ) = msg.sender.call{value: ethOut}("");
        if (!success) revert TransferFailed();
        
        emit Swap(msg.sender, token, address(0), tokenAmount, ethOut);
    }

    // ============ Callback ============

    /**
     * @notice Uniswap V4 unlock callback
     * @dev Called by PoolManager after unlock
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");
        
        SwapCallbackData memory swapData = abi.decode(data, (SwapCallbackData));
        
        // Execute the swap
        BalanceDelta delta = poolManager.swap(
            swapData.key,
            SwapParams({
                zeroForOne: swapData.zeroForOne,
                amountSpecified: swapData.amountSpecified,
                sqrtPriceLimitX96: swapData.zeroForOne 
                    ? TickMath.MIN_SQRT_PRICE + 1 
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        
        // Settle balances
        if (swapData.zeroForOne) {
            // Paid currency0 (ETH), received currency1 (token)
            _settle(swapData.key.currency0, uint256(int256(-delta.amount0())));
            _take(swapData.key.currency1, swapData.sender, uint256(int256(delta.amount1())));
            return abi.encode(uint256(int256(delta.amount1())));
        } else {
            // Paid currency1 (token), received currency0 (ETH)
            _settle(swapData.key.currency1, uint256(int256(-delta.amount1())));
            _take(swapData.key.currency0, swapData.sender, uint256(int256(delta.amount0())));
            return abi.encode(uint256(int256(delta.amount0())));
        }
    }

    /**
     * @notice Settle a currency with the PoolManager
     */
    function _settle(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            // ETH
            poolManager.settle{value: amount}();
        } else {
            // ERC20
            IERC20(Currency.unwrap(currency)).approve(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /**
     * @notice Take a currency from the PoolManager
     */
    function _take(Currency currency, address to, uint256 amount) internal {
        poolManager.take(currency, to, amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get pool info for a token
     */
    function getPoolInfo(address token) external view returns (
        bool exists,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing
    ) {
        exists = hasPool[token];
        if (exists) {
            PoolKey memory key = tokenPools[token];
            currency0 = key.currency0;
            currency1 = key.currency1;
            fee = key.fee;
            tickSpacing = key.tickSpacing;
        }
    }

    /**
     * @notice Get current pool price (sqrtPriceX96)
     */
    function getPoolPrice(address token) external view returns (uint160 sqrtPriceX96) {
        if (!hasPool[token]) return 0;
        PoolKey memory key = tokenPools[token];
        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
    }

    // ============ Receive ETH ============

    receive() external payable {}
}
