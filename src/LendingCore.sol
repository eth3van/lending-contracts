// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Liquidations } from "src/Liquidations.sol";

contract LendingCore is Liquidations {
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses
    )
        Liquidations(tokenAddresses, priceFeedAddresses)
    { }
}
