// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ILendingCore } from "../interfaces/ILendingCore.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Getters is Ownable {
    ILendingCore internal immutable i_lendingCore;

    constructor(address lendingCoreAddress) Ownable(msg.sender) {
        i_lendingCore = ILendingCore(lendingCoreAddress);
    }

    function _healthFactor(address user) internal view returns (uint256) {
        return i_lendingCore.getHealthFactor(user);
    }

    function _getMinimumHealthFactor() internal view returns (uint256) {
        return i_lendingCore.getMinimumHealthFactor();
    }

    function _getUsdValue(address token, uint256 amount) internal view returns (uint256) {
        return i_lendingCore.getUsdValue(token, amount);
    }

    function _getAllowedTokens() internal view returns (address[] memory) {
        return i_lendingCore.getAllowedTokens();
    }

    function _getCollateralBalanceOfUser(address user, address token) internal view returns (uint256) {
        return i_lendingCore.getCollateralBalanceOfUser(user, token);
    }

    function _withdrawCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateralToWithdraw,
        address, /* from */
        address /* to */
    )
        internal
    {
        // Remove unused parameters warning by commenting them
        // from and to are handled internally by LendingCore's withdrawCollateral
        i_lendingCore.withdrawCollateral(tokenCollateralAddress, amountCollateralToWithdraw);
    }

    function _paybackBorrowedAmount(address tokenToPayBack, uint256 amountToPayBack, address onBehalfOf) internal {
        i_lendingCore.paybackBorrowedAmount(tokenToPayBack, amountToPayBack, onBehalfOf);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        i_lendingCore.revertIfHealthFactorIsBroken(user);
    }

    function _getAmountOfTokenBorrowed(address user, address token) internal view returns (uint256) {
        return i_lendingCore.getAmountOfTokenBorrowed(user, token);
    }

    function _getLiquidationBonus() internal view returns (uint256) {
        return i_lendingCore.getLiquidationBonus();
    }

    function _getLiquidationPrecision() internal view returns (uint256) {
        return i_lendingCore.getLiquidationPrecision();
    }

    function _getPrecision() internal view returns (uint256) {
        return i_lendingCore.getPrecision();
    }

    function _getTokenAmountFromUsd(address token, uint256 usdAmountInWei) internal view returns (uint256) {
        return i_lendingCore.getTokenAmountFromUsd(token, usdAmountInWei);
    }

    function _getAccountCollateralValueInUsd(address user) internal view returns (uint256) {
        return i_lendingCore.getAccountCollateralValueInUsd(user);
    }

    function getUserBatch(
        uint256 batchSize,
        uint256 offset
    )
        external
        view
        returns (address[] memory users, uint256 totalUsers)
    {
        return i_lendingCore.getUserBatch(batchSize, offset);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
