// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title TradeFeeHook
 * @notice Uniswap V4 hook that applies directional trading fees
 * @dev Deployed once, shared by all graduated LaunchToken pools
 *      - Buy (ETH → Token): 1% fee
 *      - Sell (Token → ETH): 2% fee
 *      Fees are collected and sent to each token's treasury
 */
contract TradeFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for int256;
    using SafeCast for uint256;

    // ============ Constants ============

    /// @notice Buy fee in basis points (1% = 100 bps)
    uint256 public constant BUY_FEE_BPS = 100;

    /// @notice Sell fee in basis points (2% = 200 bps)
    uint256 public constant SELL_FEE_BPS = 200;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Events ============

    event PoolRegistered(PoolId indexed poolId, address indexed treasury, address indexed token);
    event FeeCollected(PoolId indexed poolId, address indexed treasury, uint256 amount, bool isBuy);

    // ============ Errors ============

    error PoolNotRegistered();
    error AlreadyRegistered();
    error Unauthorized();
    error InvalidTreasury();

    // ============ State ============

    /// @notice Mapping from pool ID to treasury address
    mapping(PoolId => address) public poolTreasuries;

    /// @notice Mapping from pool ID to token address
    mapping(PoolId => address) public poolTokens;

    /// @notice Address of the token factory (authorized to register pools)
    address public immutable factory;

    /// @notice Accumulated fees per pool (to be claimed)
    mapping(PoolId => uint256) public accumulatedFees;

    // ============ Constructor ============

    constructor(IPoolManager _poolManager, address _factory) BaseHook(_poolManager) {
        factory = _factory;
    }

    // ============ Hook Permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,           // We use beforeSwap to calculate and extract fees
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // We return a delta to collect fees
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Pool Registration ============

    /**
     * @notice Register a pool with its treasury for fee collection
     * @param key The pool key
     * @param treasury Address to receive fees
     * @param token Address of the LaunchToken
     * @dev Only callable by the factory
     */
    function registerPool(
        PoolKey calldata key,
        address treasury,
        address token
    ) external {
        if (msg.sender != factory) revert Unauthorized();
        if (treasury == address(0)) revert InvalidTreasury();

        PoolId poolId = key.toId();
        if (poolTreasuries[poolId] != address(0)) revert AlreadyRegistered();

        poolTreasuries[poolId] = treasury;
        poolTokens[poolId] = token;

        emit PoolRegistered(poolId, treasury, token);
    }

    // ============ Hook Implementation ============

    /**
     * @notice Called before a swap - calculates and extracts trading fees
     * @dev Fee direction:
     *      - zeroForOne = true (currency0 → currency1): If currency0 is ETH, this is a BUY (1% fee)
     *      - zeroForOne = false (currency1 → currency0): If currency0 is ETH, this is a SELL (2% fee)
     */
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        address treasury = poolTreasuries[poolId];

        // If pool not registered, allow swap without fee
        if (treasury == address(0)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Determine if this is a buy or sell
        // currency0 should be the native currency (ETH) for our pools
        // zeroForOne = true means ETH → Token (BUY)
        // zeroForOne = false means Token → ETH (SELL)
        bool isBuy = params.zeroForOne && key.currency0.isAddressZero();
        bool isSell = !params.zeroForOne && key.currency0.isAddressZero();

        // If neither buy nor sell pattern (e.g., token pair without native), no fee
        if (!isBuy && !isSell) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Calculate fee based on direction
        uint256 feeBps = isBuy ? BUY_FEE_BPS : SELL_FEE_BPS;

        // For exactInput swaps (amountSpecified < 0), we take fee from the input
        // For exactOutput swaps (amountSpecified > 0), we take fee from the output
        int256 amountSpecified = params.amountSpecified;

        // Calculate fee amount
        // Note: For simplicity, we calculate fee on the specified amount
        // A negative amountSpecified means exactInput
        int128 feeAmount;

        if (amountSpecified < 0) {
            // Exact input: take fee from input amount
            uint256 inputAmount = uint256(-amountSpecified);
            uint256 fee = (inputAmount * feeBps) / BPS_DENOMINATOR;
            feeAmount = int128(int256(fee));
        } else {
            // Exact output: take fee from output
            uint256 outputAmount = uint256(amountSpecified);
            uint256 fee = (outputAmount * feeBps) / BPS_DENOMINATOR;
            feeAmount = int128(int256(fee));
        }

        // Track accumulated fees
        accumulatedFees[poolId] += uint256(uint128(feeAmount));

        emit FeeCollected(poolId, treasury, uint256(uint128(feeAmount)), isBuy);

        // Return delta: positive means hook takes currency
        // For specified delta (the input/output the user specified)
        // We return the fee as specified delta to reduce user's effective input/output
        BeforeSwapDelta delta = toBeforeSwapDelta(feeAmount, 0);

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    // ============ Fee Withdrawal ============

    /**
     * @notice Withdraw accumulated fees to treasury
     * @param key The pool key
     * @dev Anyone can call this to flush fees to treasury
     */
    function withdrawFees(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        address treasury = poolTreasuries[poolId];
        if (treasury == address(0)) revert PoolNotRegistered();

        uint256 fees = accumulatedFees[poolId];
        if (fees == 0) return;

        accumulatedFees[poolId] = 0;

        // Transfer fees to treasury
        // Note: In V4, the hook would need to settle with the PoolManager
        // This is a simplified version - actual implementation would use PoolManager.take()
        (bool success, ) = treasury.call{value: fees}("");
        require(success, "Transfer failed");
    }

    // ============ View Functions ============

    /**
     * @notice Get treasury address for a pool
     * @param key The pool key
     * @return treasury Treasury address
     */
    function getTreasury(PoolKey calldata key) external view returns (address) {
        return poolTreasuries[key.toId()];
    }

    /**
     * @notice Get accumulated fees for a pool
     * @param key The pool key
     * @return fees Accumulated fee amount
     */
    function getAccumulatedFees(PoolKey calldata key) external view returns (uint256) {
        return accumulatedFees[key.toId()];
    }

    /**
     * @notice Check if a pool is registered
     * @param key The pool key
     * @return registered True if pool is registered
     */
    function isPoolRegistered(PoolKey calldata key) external view returns (bool) {
        return poolTreasuries[key.toId()] != address(0);
    }

    // ============ Receive ETH ============

    receive() external payable {}
}
