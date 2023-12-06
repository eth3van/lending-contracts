// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Lending } from "src/Lending.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Errors } from "src/libraries/Errors.sol";

contract Borrowing is Lending {
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses
    )
        Lending(tokenAddresses, priceFeedAddresses)
    { }

    function borrowFunds(address tokenToBorrow, uint256 amountToBorrow) public nonReentrant {
        _borrowFunds(tokenToBorrow, amountToBorrow);
    }

    function paybackBorrowedAmount(
        address tokenToPayBack,
        uint256 amountToPayBack,
        address onBehalfOf
    )
        public
        nonReentrant
    {
        _paybackBorrowedAmount(tokenToPayBack, amountToPayBack, onBehalfOf);
    }

    function _borrowFunds(
        address tokenToBorrow,
        uint256 amountToBorrow
    )
        private
        moreThanZero(amountToBorrow)
        isAllowedToken(tokenToBorrow)
    {
        // get the amount available to borrow
        uint256 availableToBorrow = _getAvailableToBorrow(tokenToBorrow);
        // if user is trying to borrow more than available, revert
        if (amountToBorrow > availableToBorrow) {
            revert Errors.Borrowing__NotEnoughAvailableCollateral();
        }

        // Track the specific token amounts & USD amounts borrowed
        increaseAmountOfTokenBorrowed(msg.sender, tokenToBorrow, amountToBorrow);

        // This will check if total borrowed exceeds collateral limits
        _revertIfHealthFactorIsBroken(msg.sender);

        // attempt to send borrowed amount to the msg.sender
        bool success = IERC20(tokenToBorrow).transfer(msg.sender, amountToBorrow);
        if (!success) {
            revert Errors.Borrowing__TransferFailed();
        }
        // emit event when msg.sender borrows funds
        emit UserBorrowed(msg.sender, tokenToBorrow, amountToBorrow);
    }

    function _paybackBorrowedAmount(
        address tokenToPayBack,
        uint256 amountToPayBack,
        address onBehalfOf
    )
        private
        moreThanZero(amountToPayBack)
        isAllowedToken(tokenToPayBack)
    {
        // if the address being paid on behalf of is the 0 address, revert
        if (onBehalfOf == address(0)) {
            revert Errors.Borrowing__ZeroAddressNotAllowed();
        }

        // Safety check to prevent users from overpaying their debt
        uint256 borrowedAmount = _getAmountOfTokenBorrowed(onBehalfOf, tokenToPayBack);
        if (borrowedAmount < amountToPayBack) {
            revert Errors.Borrowing__OverpaidDebt();
        }

        // Update state BEFORE external calls (CEI pattern)
        // Decrease the user's borrowed balance in our internal accounting
        // This must happen first to prevent reentrancy attacks
        decreaseAmountOfTokenBorrowed(onBehalfOf, tokenToPayBack, amountToPayBack);

        // Check health factor after repayment just in case
        _revertIfHealthFactorIsBroken(onBehalfOf);

        // Transfer tokens from user to contract
        bool success = IERC20(tokenToPayBack).transferFrom(msg.sender, address(this), amountToPayBack);

        // Check if transfer was successful
        // This is a backup check since transferFrom would normally revert on failure
        if (!success) {
            revert Errors.Borrowing__TransferFailed();
        }
        // emit event
        emit BorrowedAmountRepaid(msg.sender, onBehalfOf, tokenToPayBack, amountToPayBack);
    }

    function increaseAmountOfTokenBorrowed(address user, address token, uint256 amount) private {
        s_TokenAmountsBorrowed[user][token] += amount;
    }

    function decreaseAmountOfTokenBorrowed(address user, address token, uint256 amount) private {
        s_TokenAmountsBorrowed[user][token] -= amount;
    }

    function _getTotalCollateralOfToken(address token) private view returns (uint256 totalCollateral) {
        // loop through the allowed collateral tokens
        for (uint256 i = 0; i < _getAllowedTokens().length; i++) {
            // if the token inputted by the caller is in the loop, then
            if (_getAllowedTokens()[i] == token) {
                // Get actual token balance of contract
                totalCollateral = IERC20(token).balanceOf(address(this));
                // exit loop immediately
                break;
            }
        }
        // return the total amount of collateral of these tokens
        return totalCollateral;
    }

    function getTotalCollateralOfToken(address token) external view returns (uint256 totalCollateral) {
        return _getTotalCollateralOfToken(token);
    }

    function _getAvailableToBorrow(address token) private view returns (uint256) {
        // Get total amount of this token deposited as collateral
        uint256 totalCollateral = _getTotalCollateralOfToken(token);

        // Get total amount already borrowed of this token
        uint256 totalBorrowed = _getTotalBorrowedOfToken(token);

        // Available = Total Collateral - Total Borrowed
        return totalCollateral - totalBorrowed;
    }

    function getAvailableToBorrow(address token) external view returns (uint256) {
        return _getAvailableToBorrow(token);
    }

    /**
     * @notice Retrieves the total amount of a specific token borrowed by the caller
     * @dev Implements a secure token validation pattern before accessing borrowed amounts
     * @param token The ERC20 token address to check borrowed amounts for
     * @return uint256 The total amount borrowed of the specified token
     *
     * Security considerations:
     * - Validates token is in allowed list before accessing state
     * - Uses view function to prevent state modifications
     * - Implements zero-address checks through allowed token validation
     *
     * Gas optimization:
     * - Early return if token not in allowed list
     * - Single state read for borrowed amount
     * - Breaks loop early after token validation
     *
     * Example:
     * ```
     * address WETH = 0x...;
     * uint256 borrowed = getTotalBorrowedOfToken(WETH);
     * // Returns: 5e18 (5 WETH borrowed)
     * ```
     */
    function _getTotalBorrowedOfToken(address token) private view returns (uint256) {
        uint256 totalBorrowed = 0;
        for (uint256 i = 0; i < _getAllowedTokens().length; i++) {
            if (_getAllowedTokens()[i] == token) {
                // Use contract address to track total borrowed
                totalBorrowed = _getAmountOfTokenBorrowed(address(this), token);
                break;
            }
        }
        return totalBorrowed;
    }

    function getTotalBorrowedOfToken(address token) external view returns (uint256) {
        return _getTotalBorrowedOfToken(token);
    }
}
