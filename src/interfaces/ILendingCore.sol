// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILendingCore {
    // Core functions we need from LendingCore
    function getHealthFactor(address user) external view returns (uint256);
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256);
    function getUsdValue(address token, uint256 amount) external view returns (uint256);
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) external view returns (uint256);
    function getAccountCollateralValueInUsd(address user) external view returns (uint256);
    function getAllowedTokens() external view returns (address[] memory);
    function getMinimumHealthFactor() external view returns (uint256);
    function getLiquidationThreshold() external view returns (uint256);
    function getLiquidationPrecision() external pure returns (uint256);
    function getLiquidationBonus() external pure returns (uint256);
    function getPrecision() external pure returns (uint256);

    function withdrawCollateral(address tokenCollateralAddress, uint256 amountCollateralToWithdraw) external;
    function paybackBorrowedAmount(address tokenToPayBack, uint256 amountToPayBack, address onBehalfOf) external;

    function revertIfHealthFactorIsBroken(address user) external view;

    function getAmountOfTokenBorrowed(address user, address token) external view returns (uint256);

    function getUserBatch(
        uint256 batchSize,
        uint256 offset
    )
        external
        view
        returns (address[] memory users, uint256 totalUsers);

    function liquidationDecreaseDebt(address user, address token, uint256 amount) external;

    function liquidationWithdrawCollateral(
        address collateral,
        uint256 amount,
        address user,
        address recipient
    )
        external;

    function liquidationPaybackBorrowedAmount(
        address token,
        uint256 amount,
        address user,
        address liquidator
    )
        external;
}
