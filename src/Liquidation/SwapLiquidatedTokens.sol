// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SwapLiquidatedTokens
 * @author Evan Guo
 * @notice Handles conversion of liquidated collateral to debt tokens via Uniswap V3
 * @dev Critical component for maintaining protocol solvency after liquidations
 *
 * Key Features:
 * - Professional-grade Uniswap V3 integration
 * - Secure token handling with SafeERC20
 * - Access-controlled operations
 * - Emergency token recovery
 */
contract SwapLiquidatedTokens is Ownable {
    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    // Enable SafeERC20 functions for all IERC20 operations
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Immutable reference to Uniswap's swap router
    // This can never change after deployment, providing security
    ISwapRouter private immutable i_swapRouter;

    // Standard Uniswap V3 pool fee of 0.3%
    // Used for all swaps to ensure good liquidity
    uint24 public constant POOL_FEE = 3000; // 0.3% fee tier

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    // Event emitted after successful swaps
    // Helps with tracking and monitoring system health
    // The collateral token we're swapping from
    // The debt token we're swapping to
    // Amount of collateral token being swapped
    // Amount of debt token received
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the contract with Uniswap router address
     * @param swapRouter The address of Uniswap V3's SwapRouter contract
     */
    constructor(address swapRouter) Ownable(msg.sender) {
        i_swapRouter = ISwapRouter(swapRouter);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes a token swap on Uniswap V3
     * @dev Uses exactInputSingle for precise swap execution
     */
    function swapExactInputSingle(
        address tokenIn, // The collateral token to swap from
        address tokenOut, // The debt token to swap to
        uint256 amountIn, // Amount of collateral token to swap
        uint256 minAmountOut // Minimum amount of debt token to receive (slippage protection)
    )
        external
        onlyOwner // Only the protocol can call this
        returns (
            uint256 amountOut // The actual amount of debt token received
        )
    {
        // Approve Uniswap router to spend our tokens
        // This is safe because we trust the Uniswap router contract
        IERC20(tokenIn).approve(address(i_swapRouter), 0);
        IERC20(tokenIn).approve(address(i_swapRouter), amountIn);

        // Configure the swap parameters
        // This struct holds all the data Uniswap needs
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn, // Token we're swapping from
            tokenOut: tokenOut, // Token we're swapping to
            fee: POOL_FEE, // 0.3% pool fee
            recipient: address(this), // We receive the tokens
            deadline: block.timestamp, // Execute immediately
            amountIn: amountIn, // Amount we're swapping
            amountOutMinimum: minAmountOut, // Slippage protection
            sqrtPriceLimitX96: 0 // No price limit (0 = no limit)
         });

        // Execute the swap and store how many tokens we received
        amountOut = i_swapRouter.exactInputSingle(params);

        // Emit event for tracking and monitoring
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);

        return amountOut;
    }

    /**
     * @notice Emergency function to recover stuck tokens
     * @dev Only owner can call this (security measure)
     * @param token The token address to recover
     * @param amount Amount of tokens to recover
     */
    function recoverTokens(address token, uint256 amount) external onlyOwner {
        // Safely transfer tokens to the owner
        // Uses SafeERC20 to prevent transfer issues
        IERC20(token).safeTransfer(owner(), amount);
    }
}
