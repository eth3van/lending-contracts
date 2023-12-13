// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { HealthFactor } from "src/HealthFactor.sol";
import { CoreStorage } from "src/CoreStorage.sol";
import { Lending } from "src/Lending.sol";
import { LiquidationEngine } from "src/Liquidation/LiquidationEngine.sol";
import { LiquidationCore } from "src/Liquidation/LiquidationCore.sol";
import { Getters } from "src/Liquidation/Getters.sol";
import { Withdraw } from "src/Withdraw.sol";
import { HelperConfig } from "script/HelperConfig.s.sol";
import { DeployLendingCore } from "script/DeployLendingCore.s.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import { LendingCore } from "src/LendingCore.sol";
import { Errors } from "src/libraries/Errors.sol";
import { MockFailedTransferFrom } from "test/mocks/MockFailedTransferFrom.sol";
import { MockBorrowing } from "test/mocks/MockBorrowing.sol";
import { OracleLib } from "src/libraries/OracleLib.sol";
import { Borrowing } from "src/Borrowing.sol";
import { MockWithdraw } from "test/mocks/MockWithdraw.sol";

contract LendingCore_IntegrationsTest is Test {
    LendingCore lendingCore;
    HelperConfig helperConfig;

    HelperConfig.PriceFeeds public priceFeeds;
    HelperConfig.Tokens public tokens;
    HelperConfig.AutomationConfig public automationConfig;

    uint256 public constant DEPOSIT_AMOUNT = 5 ether;
    uint256 public constant LINK_AMOUNT_TO_BORROW = 10e18; // $100 USD
    uint256 public constant WETH_AMOUNT_TO_BORROW = 2e18; // $4,000 USD
    uint256 public constant WBTC_AMOUNT_TO_BORROW = 1e18; // $30,000 USD

    address public user = makeAddr("user"); // Address of the USER
    address public liquidator = makeAddr("liquidator"); // Address of the liquidator

    uint256 public constant STARTING_USER_BALANCE = 10 ether; // Initial balance given to test users

    // Arrays for token setup
    address[] public tokenAddresses; // Array to store allowed collateral token addresses
    address[] public feedAddresses; // Array to store corresponding price feed addresses
    uint256[] public automationValues;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    event UserBorrowed(address indexed user, address indexed token, uint256 indexed amount);

    event BorrowedAmountRepaid(
        address indexed payer, address indexed onBehalfOf, address indexed token, uint256 amount
    );

    event CollateralWithdrawn(address indexed token, uint256 amount, address indexed WithdrawnFrom, address WithdrawTo);

    function setUp() external {
        // Create a new instance of the deployment script
        DeployLendingCore deployer = new DeployLendingCore();

        // Deploy protocol (this will create its own HelperConfig)
        lendingCore = deployer.deployLendingCore();

        helperConfig = deployer.helperConfig();

        // Get config values and assign directly to state variables
        (priceFeeds, tokens, automationConfig) = helperConfig.activeNetworkConfig();

        // Set up arrays with direct struct access
        tokenAddresses = [tokens.weth, tokens.wbtc, tokens.link];
        feedAddresses = [
            priceFeeds.wethUsdPriceFeed,
            priceFeeds.wbtcUsdPriceFeed,
            priceFeeds.linkUsdPriceFeed
        ];
        automationValues = [automationConfig.deployerKey, automationConfig.upkeepId];

        // If we're on a local Anvil chain (chainId 31337), give our test user some ETH to work with
        if (block.chainid == 31_337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }

        // Mint initial balances of tokens.weth, tokens.wbtc, tokens.link to our test user
        // This allows the user to have tokens to deposit as collateral
        ERC20Mock(tokens.weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(tokens.wbtc).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(tokens.link).mint(user, STARTING_USER_BALANCE);

        ERC20Mock(tokens.weth).mint(liquidator, STARTING_USER_BALANCE);
        ERC20Mock(tokens.wbtc).mint(liquidator, STARTING_USER_BALANCE);
        ERC20Mock(tokens.link).mint(liquidator, STARTING_USER_BALANCE);

        ERC20Mock(tokens.weth).mint(address(lendingCore), WETH_AMOUNT_TO_BORROW);
        ERC20Mock(tokens.wbtc).mint(address(lendingCore), WBTC_AMOUNT_TO_BORROW);
        ERC20Mock(tokens.link).mint(address(lendingCore), LINK_AMOUNT_TO_BORROW);
    }

    //////////////////////////
    //  CoreStorage Tests  //
    /////////////////////////

    /**
     * @notice Tests that the constructor reverts when token and price feed arrays have different lengths
     * @dev This ensures proper initialization of collateral tokens and their price feeds
     * Test sequence:
     * 1. Push tokens.weth to token array
     * 2. Push ETH/USD and BTC/USD to price feed array
     * 3. Attempt to deploy CoreStorage with mismatched arrays
     * 4. Verify it reverts with correct error
     */
    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        // Setup: Create mismatched arrays
        tokenAddresses.push(tokens.weth); // Add only two tokens
        tokenAddresses.push(tokens.wbtc);

        feedAddresses.push(priceFeeds.wethUsdPriceFeed); // Add three price feeds
        feedAddresses.push(priceFeeds.wbtcUsdPriceFeed); // Creating a length mismatch
        feedAddresses.push(priceFeeds.linkUsdPriceFeed);

        // Expect revert when arrays don't match in length
        vm.expectRevert(Errors.CoreStorage__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new CoreStorage(tokenAddresses, feedAddresses);
    }

    function testCoreStorageConstructor() public {
        // Create test arrays
        address[] memory testTokens = new address[](3);
        testTokens[0] = tokens.weth;
        testTokens[1] = tokens.wbtc;
        testTokens[2] = tokens.link;

        address[] memory testFeeds = new address[](3);
        testFeeds[0] = priceFeeds.wethUsdPriceFeed;
        testFeeds[1] = priceFeeds.wbtcUsdPriceFeed;
        testFeeds[2] = priceFeeds.linkUsdPriceFeed;

        // Deploy new CoreStorage
        CoreStorage coreStorage = new CoreStorage(testTokens, testFeeds);

        // Test initialization
        address[] memory allowedTokens = coreStorage.getAllowedTokens();
        assertEq(allowedTokens.length, 3, "Should have 3 allowed tokens");
        assertEq(allowedTokens[0], tokens.weth, "First token should be tokens.weth");
        assertEq(allowedTokens[1], tokens.wbtc, "Second token should be tokens.wbtc");
        assertEq(allowedTokens[2], tokens.link, "Third token should be tokens.link");

        // Test price feed mappings
        assertEq(coreStorage.getCollateralTokenPriceFeed(tokens.weth), priceFeeds.wethUsdPriceFeed, "tokens.weth price feed mismatch");
        assertEq(coreStorage.getCollateralTokenPriceFeed(tokens.wbtc), priceFeeds.wbtcUsdPriceFeed, "tokens.wbtc price feed mismatch");
        assertEq(coreStorage.getCollateralTokenPriceFeed(tokens.link), priceFeeds.linkUsdPriceFeed, "tokens.link price feed mismatch");
    }

    function testGetCollateralBalanceOfUser() public UserDeposited {
        uint256 balance = lendingCore.getCollateralBalanceOfUser(user, tokens.weth);
        assertEq(balance, DEPOSIT_AMOUNT);
    }

    function testGetCollateralTokenPriceFeed() public view {
        // Get the price feed address for tokens.weth token
        address priceFeed = lendingCore.getCollateralTokenPriceFeed(tokens.weth);
        // Verify it matches the expected tokens.weth/USD price feed address
        assertEq(priceFeed, priceFeeds.wethUsdPriceFeed);
    }

    // Tests that the array of collateral tokens contains the expected tokens
    function testAllowedTokens() public view {
        // Get the array of allowed collateral tokens
        address[] memory collateralTokens = lendingCore.getAllowedTokens();
        // Verify tokens.weth is at index 0 (first and only token in this test)
        assertEq(collateralTokens[0], tokens.weth);
        assertEq(collateralTokens[1], tokens.wbtc);
        assertEq(collateralTokens[2], tokens.link);
    }

    function testAdditionalFeedPrecision() public view {
        uint256 feedPrecision = 1e10;

        uint256 additionalFeedPrecision = lendingCore.getAdditionalFeedPrecision();
        assertEq(additionalFeedPrecision, feedPrecision);
    }

    function testLiquidationThreshold() public view {
        uint256 liquidationThreshold = 50;
        uint256 getLiquidationThreshold = lendingCore.getLiquidationThreshold();
        assertEq(getLiquidationThreshold, liquidationThreshold);
    }

    function testLiquidationPrecision() public view {
        uint256 liquidationPrecision = 100;
        assertEq(lendingCore.getLiquidationPrecision(), liquidationPrecision);
    }

    function testPrecision() public view {
        uint256 presicion = 1e18;
        assertEq(lendingCore.getPrecision(), presicion);
    }

    function testGetMinimumHealthFactor() public view {
        uint256 minimumHealthFactor = 1e18;
        assertEq(lendingCore.getMinimumHealthFactor(), minimumHealthFactor);
    }

    function testGetLiquidationBonus() public view {
        uint256 liquidationBonus = 10;
        assertEq(lendingCore.getLiquidationBonus(), liquidationBonus);
    }

    /**
     * @notice Tests the conversion from token amount to USD value
     * @dev Verifies that getUsdValue correctly calculates USD value based on price feeds
     * Test sequence:
     * 1. Set test amount to 15 ETH
     * 2. With ETH price at $2000 (from mock), expect $30,000
     * 3. Compare actual result with expected value
     */
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; // 15 ETH
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30_000e18; // $30,000 in USD
        uint256 usdValue = lendingCore.getUsdValue(tokens.weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    /**
     * @notice Tests the conversion from USD value to token amount
     * @dev Verifies that getTokenAmountFromUsd correctly calculates token amounts based on price feeds
     * Test sequence:
     * 1. Request conversion of $100 worth of tokens.weth
     * 2. With ETH price at $2000 (from mock), expect 0.05 tokens.weth
     * 3. Compare actual result with expected amount
     */
    function testGetTokenAmountFromUsd() public view {
        // If we want $100 of tokens.weth @ $2000/tokens.weth, that would be 0.05 tokens.weth
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = lendingCore.getTokenAmountFromUsd(tokens.weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetTotalTokenAmountsBorrowed() public UserDepositedAndBorrowedLink {
        uint256 totalAmountsBorrowed = lendingCore.getTotalTokenAmountsBorrowed(tokens.link);
        uint256 expectedAmountBorrowed = 10e18;

        assertEq(totalAmountsBorrowed, expectedAmountBorrowed);
    }

    ///////////////////////////
    //  HealthFactor Tests  //
    //////////////////////////

    // Modifier to set up the test state with collateral deposited and user borrowed tokens.link
    modifier UserDepositedAndBorrowedLink() {
        // Start impersonating the test user
        vm.startPrank(user);
        // Approve the lendingCore contract to spend user's tokens.weth
        // User deposits $10,000
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);

        // Deposit collateral and borrow tokens.link in one transaction
        // tokens.link is $10/token, user borrows 10, so thats $100 borrowed
        lendingCore.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);
        // Stop impersonating the user
        vm.stopPrank();
        _;
    }

    modifier LiquidLendingCore() {
        uint256 liquidLinkVaults = 100_000e18;
        uint256 liquidWethVaults = 100_000e18;
        uint256 liquidWbtcVaults = 100_000e18;

        ERC20Mock(tokens.weth).mint(address(lendingCore), liquidLinkVaults);
        ERC20Mock(tokens.wbtc).mint(address(lendingCore), liquidWbtcVaults);
        ERC20Mock(tokens.link).mint(address(lendingCore), liquidLinkVaults);
        _;
    }

    function testHealthFactorConstructor() public {
        // Create new arrays for tokens and price feeds
        address[] memory testTokens = new address[](3);
        testTokens[0] = tokens.weth;
        testTokens[1] = tokens.wbtc;
        testTokens[2] = tokens.link;

        address[] memory testFeeds = new address[](3);
        testFeeds[0] = priceFeeds.wethUsdPriceFeed;
        testFeeds[1] = priceFeeds.wbtcUsdPriceFeed;
        testFeeds[2] = priceFeeds.linkUsdPriceFeed;

        // Deploy new HealthFactor instance
        HealthFactor healthFactor = new HealthFactor(testTokens, testFeeds);

        // Verify initialization
        address[] memory allowedTokens = healthFactor.getAllowedTokens();
        assertEq(allowedTokens.length, 3, "Should have 3 allowed tokens");
        assertEq(allowedTokens[0], tokens.weth, "First token should be tokens.weth");
        assertEq(allowedTokens[1], tokens.wbtc, "Second token should be tokens.wbtc");
        assertEq(allowedTokens[2], tokens.link, "Third token should be tokens.link");

        // Verify price feed mappings
        assertEq(
            healthFactor.getCollateralTokenPriceFeed(tokens.weth), priceFeeds.wethUsdPriceFeed, "tokens.weth price feed mismatch"
        );
        assertEq(
            healthFactor.getCollateralTokenPriceFeed(tokens.wbtc), priceFeeds.wbtcUsdPriceFeed, "tokens.wbtc price feed mismatch"
        );
        assertEq(
            healthFactor.getCollateralTokenPriceFeed(tokens.link), priceFeeds.linkUsdPriceFeed, "tokens.link price feed mismatch"
        );
    }

    // Tests that the health factor is calculated correctly for a user's position
    function testProperlyReportsHealthFactorWhenUserHasNotBorrowed() public UserDeposited {
        // since the user has not borrowed anything, his health score should be perfect!
        uint256 expectedHealthFactor = type(uint256).max;
        uint256 healthFactor = lendingCore.getHealthFactor(user);
        // $0 borrowed with $10,000 collateral at 50% liquidation threshold
        // 10,000 * 0.5 = 5,000
        // 5,000 / 0 = prefect health factor

        // Verify that the calculated health factor matches expected value
        assertEq(healthFactor, expectedHealthFactor);
    }

    // Tests that the health factor is calculated correctly for a user's position
    function testProperlyReportsHealthFactorWhenUserHasBorrowed() public UserDepositedAndBorrowedLink {
        // since the user has borrowed $100, his health score should be 50! anything over 1 is good!
        uint256 expectedHealthFactor = 50e18;
        uint256 healthFactor = lendingCore.getHealthFactor(user);
        // $100 borrowed with $10,000 collateral at 50% liquidation threshold
        // 10,000 * 0.5 = 5,000
        // 5,000 / 100 = 50 health factor

        // Verify that the calculated health factor matches expected value
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testUserHealthIsMaxWhenUserHasNotDeposited() public view {
        uint256 expectedHealthFactor = type(uint256).max;
        uint256 healthFactor = lendingCore.getHealthFactor(user);

        assertEq(healthFactor, expectedHealthFactor);
    }

    function testGetAccountCollateralValueInUsd() public UserDeposited {
        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingEngine to spend user's tokens.weth
        ERC20Mock(tokens.wbtc).approve(address(lendingCore), DEPOSIT_AMOUNT);
        ERC20Mock(tokens.link).approve(address(lendingCore), DEPOSIT_AMOUNT);
        lendingCore.depositCollateral(tokens.wbtc, DEPOSIT_AMOUNT);
        lendingCore.depositCollateral(tokens.link, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // user deposited 5tokens.link($10/Token) + 5 tokens.weth($2000/Token) + 5tokens.wbtc($30,000) = $160,050
        uint256 expectedDepositedAmountInUsd = 160_050e18;
        assertEq(lendingCore.getAccountCollateralValueInUsd(user), expectedDepositedAmountInUsd);
    }

    function testGetAccountBorrowedValueInUsd() public UserDeposited {
        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingEngine to spend user's tokens.weth
        ERC20Mock(tokens.wbtc).approve(address(lendingCore), DEPOSIT_AMOUNT);
        ERC20Mock(tokens.link).approve(address(lendingCore), DEPOSIT_AMOUNT);
        // user deposited 5tokens.link($10/Token) + 5 tokens.weth($2000/Token) + 5tokens.wbtc($30,000) = $160,050
        lendingCore.depositCollateral(tokens.wbtc, DEPOSIT_AMOUNT);
        lendingCore.depositCollateral(tokens.link, DEPOSIT_AMOUNT);
        // user borrows $100 in tokens.link
        lendingCore.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);
        // user borrows $4,000 in tokens.weth
        lendingCore.borrowFunds(tokens.weth, WETH_AMOUNT_TO_BORROW);
        // user borrows $30,000 in tokens.wbtc
        lendingCore.borrowFunds(tokens.wbtc, WBTC_AMOUNT_TO_BORROW);
        vm.stopPrank();

        uint256 expectedBorrowedAmountInUsd = 34_100e18;
        assertEq(lendingCore.getAccountBorrowedValueInUsd(user), expectedBorrowedAmountInUsd);
    }

    function testGetAccountInformation() public UserDepositedAndBorrowedLink {
        uint256 expectedTotalAmountBorrowed = 100e18;
        uint256 expectedCollateralValueInUsd = 10_000e18;

        (uint256 totalAmountBorrowed, uint256 collateralValueInUsd) = lendingCore.getAccountInformation(user);

        assertEq(totalAmountBorrowed, expectedTotalAmountBorrowed);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }

    function testRevertIfHealthFactorIsBroken() public UserDeposited LiquidLendingCore {
        uint256 link_amount_borrowed_reverts = 1000e18; // 1000 tokens.link = $10,000
        uint256 expectedHealthFactor = 5e17; // 0.5e18

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.HealthFactor__BreaksHealthFactor.selector, expectedHealthFactor));
        lendingCore.borrowFunds(tokens.link, link_amount_borrowed_reverts);
    }

    function testCalculateHealthFactor() public view {
        uint256 totalAmountBorrowed = 100; // $100 USD
        uint256 depositAmountInUsd = 1000; // $1000 USD
        // Health factor is 5 since we Adjust collateral value by liquidation threshold
        uint256 expectedHealthFactor = 5e18;

        // grab and save the returned healthFactor from the function call
        (uint256 healthFactor) = lendingCore.calculateHealthFactor(totalAmountBorrowed, depositAmountInUsd);
        // assert the values
        assertEq(healthFactor, expectedHealthFactor);
    }

    // Tests that the health factor can go below 1 when collateral value drops
    function testHealthFactorCanGoBelowOne() public UserDepositedAndBorrowedLink {
        // Set new ETH price to $18 (significant drop from original price)
        int256 wethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        // we need $200 at all times if we have $100 of debt
        // Update the ETH/USD price feed with new lower price
        MockV3Aggregator(priceFeeds.wethUsdPriceFeed).updateAnswer(wethUsdUpdatedPrice);

        // Get user's new health factor after price drop
        uint256 userHealthFactor = lendingCore.getHealthFactor(user);

        // Health factor calculation explanation:
        // 180 (ETH price) * 50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION)
        // / 100 (PRECISION) = 90 / 100 (totalAmountBorrowed) = 0.9

        // Verify health factor is now below 1 (0.45)
        assertEq(userHealthFactor, 45e16); // 0.45 ether
    }

    ///////////////////////////
    //  LendingEngine Tests  //
    //////////////////////////

    function testLendingConstructor() public {
        // Create new arrays for tokens and price feeds
        address[] memory testTokens = new address[](3);
        testTokens[0] = tokens.weth;
        testTokens[1] = tokens.wbtc;
        testTokens[2] = tokens.link;

        address[] memory testFeeds = new address[](3);
        testFeeds[0] = priceFeeds.wethUsdPriceFeed;
        testFeeds[1] = priceFeeds.wbtcUsdPriceFeed;
        testFeeds[2] = priceFeeds.linkUsdPriceFeed;

        // Deploy new HealthFactor instance
        Lending lending = new Lending(testTokens, testFeeds);

        // Verify initialization
        address[] memory allowedTokens = lending.getAllowedTokens();
        assertEq(allowedTokens.length, 3, "Should have 3 allowed tokens");
        assertEq(allowedTokens[0], tokens.weth, "First token should be tokens.weth");
        assertEq(allowedTokens[1], tokens.wbtc, "Second token should be tokens.wbtc");
        assertEq(allowedTokens[2], tokens.link, "Third token should be tokens.link");

        // Verify price feed mappings
        assertEq(lending.getCollateralTokenPriceFeed(tokens.weth), priceFeeds.wethUsdPriceFeed, "tokens.weth price feed mismatch");
        assertEq(lending.getCollateralTokenPriceFeed(tokens.wbtc), priceFeeds.wbtcUsdPriceFeed, "tokens.wbtc price feed mismatch");
        assertEq(lending.getCollateralTokenPriceFeed(tokens.link), priceFeeds.linkUsdPriceFeed, "tokens.link price feed mismatch");
    }

    // testing deposit function
    function testDepositWorks() public {
        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingEngine to spend user's tokens.weth
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        // Deposit the collateral
        lendingCore.depositCollateral(address(tokens.weth), DEPOSIT_AMOUNT);
        vm.stopPrank();
        uint256 expectedDepositedAmount = 5 ether;
        assertEq(lendingCore.getCollateralBalanceOfUser(user, tokens.weth), expectedDepositedAmount);
    }

    function testDepositRevertsWhenDepositingZero() public {
        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingEngine to spend user's tokens.weth
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        vm.expectRevert(Errors.AmountNeedsMoreThanZero.selector);
        // Deposit the collateral
        lendingCore.depositCollateral(address(tokens.weth), 0);
        vm.stopPrank();
    }

    function testDepositRevertsWithUnapprovedCollateral() public {
        // Create a new random ERC20 token
        ERC20Mock dogToken = new ERC20Mock("DOG", "DOG", user, 100e18);

        // Start impersonating our test user
        vm.startPrank(user);

        // Expect revert with TokenNotAllowed error when trying to deposit unapproved token
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotAllowed.selector, address(dogToken)));
        // Attempt to deposit unapproved token as collateral (this should fail)
        lendingCore.depositCollateral(address(dogToken), DEPOSIT_AMOUNT);

        // Stop impersonating the user
        vm.stopPrank();
    }

    function testRevertsIfUserHasLessThanDeposit() public {
        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingEngine to spend user's tokens.weth
        ERC20Mock(tokens.weth).approve(address(lendingCore), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Errors.Lending__YouNeedMoreFunds.selector));
        lendingCore.depositCollateral(tokens.weth, 100 ether);
        vm.stopPrank();
    }

    modifier UserDeposited() {
        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingEngine to spend user's tokens.weth
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);
        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testUpdatesUsersBalanceMappingWhenUserDeposits() public UserDeposited {
        assertEq(lendingCore.getCollateralBalanceOfUser(user, tokens.weth), DEPOSIT_AMOUNT);
    }

    function testDepositEmitsEventWhenUserDeposits() public {
        // Set up the transaction that will emit the event
        vm.startPrank(user);
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        // Set up the event expectation immediately before the emitting call
        vm.expectEmit(true, true, true, false, address(lendingCore));
        emit CollateralDeposited(user, tokens.weth, DEPOSIT_AMOUNT);

        // Make the call that should emit the event
        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testTokenTransferFromWorksWhenDepositing() public {
        // Record balances before deposit
        uint256 userBalanceBefore = ERC20Mock(tokens.weth).balanceOf(user);
        uint256 contractBalanceBefore = ERC20Mock(tokens.weth).balanceOf(address(lendingCore));

        // Prank User and approve deposit
        vm.startPrank(user);
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        // Make deposit
        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Check balances after deposit
        uint256 userBalanceAfter = ERC20Mock(tokens.weth).balanceOf(user);
        uint256 contractBalanceAfter = ERC20Mock(tokens.weth).balanceOf(address(lendingCore));

        // Verify balances changed correctly
        assertEq(userBalanceBefore - userBalanceAfter, DEPOSIT_AMOUNT, "User balance should decrease by deposit amount");
        assertEq(
            contractBalanceAfter - contractBalanceBefore,
            DEPOSIT_AMOUNT,
            "Contract balance should increase by deposit amount"
        );
    }

    function testDepositRevertsOnFailedTransfer() public {
        // Setup - Get the owner's address (msg.sender in this context)
        address owner = msg.sender;

        // Create new mock token contract that will fail transfers, deployed by owner
        vm.prank(owner);
        MockFailedTransferFrom mockDeposit = new MockFailedTransferFrom();

        // Setup array with mock token as only allowed collateral
        tokenAddresses = [address(mockDeposit)];
        // Setup array with tokens.weth price feed for the mock token
        feedAddresses = [priceFeeds.wethUsdPriceFeed];

        // Deploy new LendingCore instance with mock token as allowed collateral
        vm.prank(owner);
        LendingCore mockLendingCore = new LendingCore(
            tokenAddresses,
            feedAddresses,
            address(0), // Mock swap router
            address(0), // Mock automation registry
            0 // Mock upkeep ID
        );

        // Mint some mock tokens to our test user
        mockDeposit.mint(user, DEPOSIT_AMOUNT);

        // Transfer ownership of mock token to LendingCore
        vm.prank(owner);
        mockDeposit.transferOwnership(address(mockLendingCore));

        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingCore to spend user's tokens
        mockDeposit.approve(address(mockLendingCore), DEPOSIT_AMOUNT);

        // Expect the transaction to revert with TransferFailed error
        vm.expectRevert(Errors.TransferFailed.selector);
        // Attempt to deposit collateral (this should fail)
        mockLendingCore.depositCollateral(address(mockDeposit), DEPOSIT_AMOUNT);

        // Stop impersonating the user
        vm.stopPrank();
    }

    /////////////////////////////
    //     Borrowing Tests    //
    ////////////////////////////

    function testBorrowingConstructor() public {
        // Create new arrays for tokens and price feeds
        address[] memory testTokens = new address[](3);
        testTokens[0] = tokens.weth;
        testTokens[1] = tokens.wbtc;
        testTokens[2] = tokens.link;

        address[] memory testFeeds = new address[](3);
        testFeeds[0] = priceFeeds.wethUsdPriceFeed;
        testFeeds[1] = priceFeeds.wbtcUsdPriceFeed;
        testFeeds[2] = priceFeeds.linkUsdPriceFeed;

        // Deploy new HealthFactor instance
        Borrowing borrowing = new Borrowing(testTokens, testFeeds);

        // Verify initialization
        address[] memory allowedTokens = borrowing.getAllowedTokens();
        assertEq(allowedTokens.length, 3, "Should have 3 allowed tokens");
        assertEq(allowedTokens[0], tokens.weth, "First token should be tokens.weth");
        assertEq(allowedTokens[1], tokens.wbtc, "Second token should be tokens.wbtc");
        assertEq(allowedTokens[2], tokens.link, "Third token should be tokens.link");

        // Verify price feed mappings
        assertEq(borrowing.getCollateralTokenPriceFeed(tokens.weth), priceFeeds.wethUsdPriceFeed, "tokens.weth price feed mismatch");
        assertEq(borrowing.getCollateralTokenPriceFeed(tokens.wbtc), priceFeeds.wbtcUsdPriceFeed, "tokens.wbtc price feed mismatch");
        assertEq(borrowing.getCollateralTokenPriceFeed(tokens.link), priceFeeds.linkUsdPriceFeed, "tokens.link price feed mismatch");
    }

    function testBorrowingWorksProperly() public UserDeposited {
        // get the amount the user borrowed before (which is 0)
        uint256 amountBorrowedBefore = lendingCore.getAmountOfTokenBorrowed(user, tokens.link);
        // how much the user should be borrowing
        uint256 expectedAmountBorrowed = 10e18;
        // the next call comes from the user
        vm.prank(user);
        // borrow funds
        lendingCore.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);

        // get the amount the user borrowed
        uint256 amountBorrowedAfter = lendingCore.getAmountOfTokenBorrowed(user, tokens.link);

        // assert that the amount the user borrowed after the borrow call is more than before
        assert(amountBorrowedAfter > amountBorrowedBefore);
        // assert that the expected amount to borrow is what was borrowed
        assertEq(amountBorrowedAfter, expectedAmountBorrowed);
    }

    function testRevertIfUserBorrowsZero() public UserDeposited {
        uint8 borrowZeroAmount = 0;
        vm.prank(user);
        vm.expectRevert(Errors.AmountNeedsMoreThanZero.selector);
        lendingCore.borrowFunds(tokens.link, borrowZeroAmount);
    }

    function testBorrowRevertsWithUnapprovedToken() public UserDeposited {
        // Create a new random ERC20 token
        ERC20Mock dogToken = new ERC20Mock("DOG", "DOG", user, 100e18);

        // Start impersonating our test user
        vm.startPrank(user);

        // Expect revert with TokenNotAllowed error when trying to borrow unapproved token
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotAllowed.selector, address(dogToken)));
        // Attempt to borrow unapproved token as collateral (this should fail)
        lendingCore.borrowFunds(address(dogToken), LINK_AMOUNT_TO_BORROW);

        // Stop impersonating the user
        vm.stopPrank();
    }

    function testRevertsWhenThereIsNoCollateral() public UserDepositedAndBorrowedLink {
        address otherUser = makeAddr("otherUser");
        ERC20Mock(tokens.weth).mint(otherUser, STARTING_USER_BALANCE);

        // Start impersonating the test user
        vm.startPrank(otherUser);
        // Approve the lendingCore contract to spend user's tokens.weth
        // User deposits $10,000
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);

        // test should revert since there is no tokens.link in the contract
        vm.expectRevert(Errors.Borrowing__NotEnoughAvailableCollateral.selector);
        // Deposit collateral and borrow tokens.link
        lendingCore.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);
        // Stop impersonating the user
        vm.stopPrank();

        uint256 actualAmountOfLinkInContract = lendingCore.getTotalCollateralOfToken(tokens.link);
        uint256 expectedAmountOfLinkInContract = 0;
        assertEq(actualAmountOfLinkInContract, expectedAmountOfLinkInContract);
    }

    function testRevertsWhenThereIsNotEnoughCollateral() public UserDepositedAndBorrowedLink {
        uint256 twoLinkTokensAvailable = 2e18;
        ERC20Mock(tokens.link).mint(address(lendingCore), twoLinkTokensAvailable);

        address otherUser = makeAddr("otherUser");
        ERC20Mock(tokens.weth).mint(otherUser, STARTING_USER_BALANCE);

        // Start impersonating the test user
        vm.startPrank(otherUser);
        // Approve the lendingCore contract to spend user's tokens.weth
        // User deposits $10,000
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);

        // test should revert since there is no tokens.link in the contract
        vm.expectRevert(Errors.Borrowing__NotEnoughAvailableCollateral.selector);
        // Deposit collateral and borrow tokens.link
        lendingCore.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);
        // Stop impersonating the user
        vm.stopPrank();

        uint256 actualAmountOfLinkInContract = lendingCore.getTotalCollateralOfToken(tokens.link);
        uint256 expectedAmountOfLinkInContract = 2e18;
        assertEq(actualAmountOfLinkInContract, expectedAmountOfLinkInContract);
    }

    function testMappingsAreCorrectlyUpdatedAfterBorrowing() public UserDepositedAndBorrowedLink {
        uint256 amountBorrowed = lendingCore.getAmountOfTokenBorrowed(user, tokens.link);
        uint256 expectedAmountBorrowedInMapping = 10e18;

        uint256 amountBorrowedInUsd = lendingCore.getAccountBorrowedValueInUsd(user);
        uint256 expectedAmountBorrowedInUsd = 100e18;

        assertEq(amountBorrowed, expectedAmountBorrowedInMapping);
        assertEq(amountBorrowedInUsd, expectedAmountBorrowedInUsd);
    }

    function testBorrowTransfersAreWorkProperly() public UserDeposited {
        uint256 userLinkBalanceBefore = ERC20Mock(tokens.link).balanceOf(user);
        // Start impersonating the test user
        vm.startPrank(user);
        // Approve the lendingCore contract to spend user's tokens.weth
        // User deposits $10,000
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);

        // Deposit collateral and borrow tokens.link in one transaction
        // tokens.link is $10/token, user borrows 10, so thats $100 borrowed
        lendingCore.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);
        // Stop impersonating the user
        vm.stopPrank();
        uint256 userLinkBalanceAfter = ERC20Mock(tokens.link).balanceOf(user);

        assert(userLinkBalanceAfter > userLinkBalanceBefore);
        assertEq(
            userLinkBalanceAfter - userLinkBalanceBefore,
            LINK_AMOUNT_TO_BORROW,
            "User should receive borrowed tokens.link tokens"
        );
    }

    function testRevertsIfBorrowTransferFailed() public {
        // Setup - Get the owner's address (msg.sender in this context)
        address owner = msg.sender;

        // Create new mock token contract that will fail transfers, deployed by owner
        vm.prank(owner);
        MockBorrowing mockBorrowing = new MockBorrowing();

        // Setup array with mock token as only allowed collateral
        tokenAddresses = [address(mockBorrowing)];
        // Setup array with tokens.weth price feed for the mock token
        feedAddresses = [priceFeeds.wethUsdPriceFeed];

        // Deploy new LendingCore instance with mock token as allowed collateral
        vm.prank(owner);
        LendingCore mockLendingCore = new LendingCore(
            tokenAddresses,
            feedAddresses,
            address(0), // Mock swap router
            address(0), // Mock automation registry
            0 // Mock upkeep ID
        );

        // Mint some mock tokens to our test user
        mockBorrowing.mint(user, DEPOSIT_AMOUNT);

        // Transfer ownership of mock token to LendingCore
        vm.prank(owner);
        mockBorrowing.transferOwnership(address(mockLendingCore));

        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingCore to spend user's tokens
        mockBorrowing.approve(address(mockLendingCore), DEPOSIT_AMOUNT);

        // deposit collateral
        mockLendingCore.depositCollateral(address(mockBorrowing), DEPOSIT_AMOUNT);

        // Expect the transaction to revert with TransferFailed error
        vm.expectRevert(Errors.TransferFailed.selector);
        mockBorrowing.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);
        // Stop impersonating the user
        vm.stopPrank();
    }

    function testBorrowingFundsEmitsEvent() public UserDeposited {
        // Set up the transaction that will emit the event
        vm.prank(user);
        // Set up the event expectation immediately before the emitting call
        vm.expectEmit(true, true, true, false, address(lendingCore));
        emit UserBorrowed(user, tokens.link, LINK_AMOUNT_TO_BORROW);
        lendingCore.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);
    }

    function testPaybackBorrowedAmountWorksProperly() public UserDepositedAndBorrowedLink {
        vm.startPrank(user);
        ERC20Mock(tokens.link).approve(address(lendingCore), LINK_AMOUNT_TO_BORROW);

        lendingCore.paybackBorrowedAmount(tokens.link, LINK_AMOUNT_TO_BORROW, user);
        vm.stopPrank();

        uint256 amountBorrowedAfterPayingBackDebt = lendingCore.getAmountOfTokenBorrowed(user, tokens.link);

        assertEq(amountBorrowedAfterPayingBackDebt, 0, "Debt should be fully paid back");
    }

    function testPaybackBorrowedAmountRevertsIfAmountIsZero() public UserDepositedAndBorrowedLink {
        uint256 amountPaidBackZero = 0;
        vm.prank(user);
        vm.expectRevert(Errors.AmountNeedsMoreThanZero.selector);
        lendingCore.paybackBorrowedAmount(tokens.link, amountPaidBackZero, user);
    }

    function testPaybackBorrowedAmountRevertsWithUnapprovedToken() public UserDepositedAndBorrowedLink {
        // Create a new random ERC20 token
        ERC20Mock dogToken = new ERC20Mock("DOG", "DOG", user, 100e18);

        // Start impersonating our test user
        vm.startPrank(user);

        // Expect revert with TokenNotAllowed error when trying to borrow unapproved token
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotAllowed.selector, address(dogToken)));
        // Attempt to borrow unapproved token  (this should fail)
        lendingCore.paybackBorrowedAmount(address(dogToken), LINK_AMOUNT_TO_BORROW, user);

        // Stop impersonating the user
        vm.stopPrank();
    }

    function testPaybackBorrowedAmountRevertsWithZeroAddress() public UserDepositedAndBorrowedLink {
        // Start impersonating our test user
        vm.startPrank(user);

        // Expect revert with TokenNotAllowed error when trying to deposit unapproved token
        vm.expectRevert(Errors.ZeroAddressNotAllowed.selector);
        // Attempt to payback on behalf of the zero address (this should fail)
        lendingCore.paybackBorrowedAmount(tokens.link, LINK_AMOUNT_TO_BORROW, address(0));

        // Stop impersonating the user
        vm.stopPrank();
    }

    function testBorrowing__NotEnoughTokensToPayDebt() public UserDepositedAndBorrowedLink {
        uint256 overpayAmountToPayBack = 10_000e18;

        // Start impersonating our test user
        vm.startPrank(user);

        // Expect revert with Borrowing__NotEnoughTokensToPayDebt error when trying to deposit unapproved token
        vm.expectRevert(Errors.Borrowing__NotEnoughTokensToPayDebt.selector);
        // Attempt to payback too much (this should fail)
        lendingCore.paybackBorrowedAmount(tokens.link, overpayAmountToPayBack, user);

        // Stop impersonating the user
        vm.stopPrank();
    }

    function testPaybackBorrowedAmountRevertsWhenUserOverPaysDebt() public UserDepositedAndBorrowedLink {
        uint256 overpayAmountToPayBack = 10_000e18;

        ERC20Mock(tokens.link).mint(user, overpayAmountToPayBack);

        // Start impersonating our test user
        vm.startPrank(user);

        // Expect revert with Borrowing__OverpaidDebt error when trying to deposit unapproved token
        vm.expectRevert(Errors.Borrowing__OverpaidDebt.selector);
        // Attempt to payback too much (this should fail)
        lendingCore.paybackBorrowedAmount(tokens.link, overpayAmountToPayBack, user);

        // Stop impersonating the user
        vm.stopPrank();
    }

    function testBorrowedAmountMappingDecreasesWhenUserPayDebts() public UserDepositedAndBorrowedLink {
        uint256 amountBorrowed = lendingCore.getAmountOfTokenBorrowed(user, tokens.link);

        vm.startPrank(user);
        ERC20Mock(tokens.link).approve(address(lendingCore), LINK_AMOUNT_TO_BORROW);

        lendingCore.paybackBorrowedAmount(tokens.link, LINK_AMOUNT_TO_BORROW, user);
        vm.stopPrank();

        uint256 amountBorrowedAfterDebtPaid = lendingCore.getAmountOfTokenBorrowed(user, tokens.link);

        assert(amountBorrowed > amountBorrowedAfterDebtPaid);
        assertEq(amountBorrowedAfterDebtPaid, 0);
    }

    function testHealthFactorImprovesAfterRepayment() public UserDepositedAndBorrowedLink {
        uint256 healthFactorWhileBorrowing = lendingCore.getHealthFactor(user);

        vm.startPrank(user);
        ERC20Mock(tokens.link).approve(address(lendingCore), LINK_AMOUNT_TO_BORROW);

        lendingCore.paybackBorrowedAmount(tokens.link, LINK_AMOUNT_TO_BORROW, user);
        vm.stopPrank();

        uint256 healthFactorAfterRepayment = lendingCore.getHealthFactor(user);

        uint256 perfectHealthScoreAfterRepayment = type(uint256).max;

        assert(healthFactorWhileBorrowing < healthFactorAfterRepayment);
        assertEq(healthFactorAfterRepayment, perfectHealthScoreAfterRepayment);
    }

    function testUserCanRepayAPortionOfDebtInsteadOfFullDebt() public UserDepositedAndBorrowedLink {
        uint256 amountBorrowedBeforeRepayment = lendingCore.getAmountOfTokenBorrowed(user, tokens.link);
        uint256 smallRepayment = 4e18;
        vm.startPrank(user);
        ERC20Mock(tokens.link).approve(address(lendingCore), smallRepayment);

        lendingCore.paybackBorrowedAmount(tokens.link, smallRepayment, user);
        vm.stopPrank();

        uint256 amountBorrowedAfterRepayment = lendingCore.getAmountOfTokenBorrowed(user, tokens.link);
        uint256 expectedDebtLeft = 6e18;

        assert(amountBorrowedBeforeRepayment > amountBorrowedAfterRepayment);
        assertEq(amountBorrowedBeforeRepayment - smallRepayment, expectedDebtLeft);
    }

    function testUsersHealthFactorImprovesAfterPartialRepayment() public UserDepositedAndBorrowedLink {
        uint256 healthFactorBeforeRepayment = lendingCore.getHealthFactor(user);
        uint256 smallRepayment = 5e18;
        vm.startPrank(user);
        ERC20Mock(tokens.link).approve(address(lendingCore), smallRepayment);

        lendingCore.paybackBorrowedAmount(tokens.link, smallRepayment, user);
        vm.stopPrank();
        uint256 healthFactorAfterRepayment = lendingCore.getHealthFactor(user);

        uint256 expectedHealthFactor = 100e18;

        assert(healthFactorBeforeRepayment < healthFactorAfterRepayment);
        assertEq(healthFactorAfterRepayment, expectedHealthFactor);
    }

    function testOtherUsersCanRepayOnHalfOfOthers() public UserDepositedAndBorrowedLink {
        uint256 amountToRepay = 10e18;
        // Setup: User2 who will attempt the repayment
        address user2 = makeAddr("user2");
        vm.startPrank(user2);

        ERC20Mock(tokens.link).mint(user2, 100e18);
        ERC20Mock(tokens.link).approve(address(lendingCore), amountToRepay);

        lendingCore.paybackBorrowedAmount(tokens.link, amountToRepay, user);

        vm.stopPrank();

        assertEq(lendingCore.getAmountOfTokenBorrowed(user, tokens.link), 0);
    }

    function testRevertsIfUsersRepaymentFails() public {
        uint256 amountToRepay = 10e18;

        // Setup - Get the owner's address (msg.sender in this context)
        address owner = msg.sender;

        // Create new mock token contract that will fail transfers, deployed by owner
        vm.prank(owner);
        MockBorrowing mockBorrowing = new MockBorrowing();

        // Setup array with mock token as only allowed collateral
        tokenAddresses = [address(mockBorrowing)];
        // Setup array with tokens.weth price feed for the mock token
        feedAddresses = [priceFeeds.wethUsdPriceFeed];

        // Deploy new LendingCore instance with mock token as allowed collateral
        vm.prank(owner);
        LendingCore mockLendingCore = new LendingCore(
            tokenAddresses,
            feedAddresses,
            address(0), // Mock swap router
            address(0), // Mock automation registry
            0 // Mock upkeep ID
        );

        // Mint some mock tokens to our test user
        mockBorrowing.mint(user, DEPOSIT_AMOUNT);

        // Transfer ownership of mock token to LendingCore
        vm.prank(owner);
        mockBorrowing.transferOwnership(address(mockLendingCore));

        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingCore to spend user's tokens
        mockBorrowing.approve(address(mockLendingCore), DEPOSIT_AMOUNT);

        // deposit collateral
        mockLendingCore.depositCollateral(address(mockBorrowing), DEPOSIT_AMOUNT);

        // Try to borrow the mock token
        mockLendingCore.borrowFunds(address(mockBorrowing), WETH_AMOUNT_TO_BORROW);

        // Expect the transaction to revert with TransferFailed error
        vm.expectRevert(Errors.TransferFailed.selector);
        mockBorrowing.paybackBorrowedAmount(address(mockBorrowing), amountToRepay, user);

        vm.stopPrank();
    }

    function testRepaymentEmitsEvent() public UserDepositedAndBorrowedLink {
        uint256 amountToRepay = 10e18;
        vm.startPrank(user);
        ERC20Mock(tokens.link).approve(address(lendingCore), amountToRepay);

        vm.expectEmit(true, true, true, true, address(lendingCore));
        emit BorrowedAmountRepaid(user, user, tokens.link, amountToRepay);

        lendingCore.paybackBorrowedAmount(tokens.link, amountToRepay, user);
        vm.stopPrank();
    }

    function testGetTotalCollateralOfToken() public view {
        uint256 expectedCollateralAmount = 10e18;

        uint256 actualCollateralAmount = lendingCore.getTotalCollateralOfToken(tokens.link);

        assertEq(actualCollateralAmount, expectedCollateralAmount);
    }

    function testGetAvailableToBorrow() public view {
        uint256 expectedCollateral = 10e18;
        uint256 actualCollateral = lendingCore.getAvailableToBorrow(tokens.link);

        assertEq(actualCollateral, expectedCollateral);
    }

    ///////////////////////////
    //     Withdraw Tests    //
    //////////////////////////

    function testWithdrawConstructor() public {
        // Create new arrays for tokens and price feeds
        address[] memory testTokens = new address[](3);
        testTokens[0] = tokens.weth;
        testTokens[1] = tokens.wbtc;
        testTokens[2] = tokens.link;

        address[] memory testFeeds = new address[](3);
        testFeeds[0] = priceFeeds.wethUsdPriceFeed;
        testFeeds[1] = priceFeeds.wbtcUsdPriceFeed;
        testFeeds[2] = priceFeeds.linkUsdPriceFeed;

        // Deploy new HealthFactor instance
        Withdraw withdraw = new Withdraw(testTokens, testFeeds);

        // Verify initialization
        address[] memory allowedTokens = withdraw.getAllowedTokens();
        assertEq(allowedTokens.length, 3, "Should have 3 allowed tokens");
        assertEq(allowedTokens[0], tokens.weth, "First token should be tokens.weth");
        assertEq(allowedTokens[1], tokens.wbtc, "Second token should be tokens.wbtc");
        assertEq(allowedTokens[2], tokens.link, "Third token should be tokens.link");

        // Verify price feed mappings
        assertEq(withdraw.getCollateralTokenPriceFeed(tokens.weth), priceFeeds.wethUsdPriceFeed, "tokens.weth price feed mismatch");
        assertEq(withdraw.getCollateralTokenPriceFeed(tokens.wbtc), priceFeeds.wbtcUsdPriceFeed, "tokens.wbtc price feed mismatch");
        assertEq(withdraw.getCollateralTokenPriceFeed(tokens.link), priceFeeds.linkUsdPriceFeed, "tokens.link price feed mismatch");
    }

    modifier UserBorrowedAndRepaidDebt() {
        // Start impersonating the test user
        vm.startPrank(user);
        // Approve the lendingCore contract to spend user's tokens.weth
        // User deposits $10,000
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);

        // Deposit collateral and borrow tokens.link in one transaction
        // tokens.link is $10/token, user borrows 10, so thats $100 borrowed
        lendingCore.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);
        ERC20Mock(tokens.link).approve(address(lendingCore), LINK_AMOUNT_TO_BORROW);

        lendingCore.paybackBorrowedAmount(tokens.link, LINK_AMOUNT_TO_BORROW, user);
        // Stop impersonating the user
        vm.stopPrank();
        _;
    }

    function testUserCanDepositAndWithdrawImmediately() public UserDeposited {
        uint256 expectedWithdrawAmount = 5 ether;
        uint256 balanceBeforeWithdrawal = ERC20Mock(tokens.weth).balanceOf(user);
        vm.startPrank(user);

        lendingCore.withdrawCollateral(tokens.weth, DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 balanceAfterWithdrawal = ERC20Mock(tokens.weth).balanceOf(user);

        assert(balanceAfterWithdrawal > balanceBeforeWithdrawal);
        assertEq(balanceAfterWithdrawal - balanceBeforeWithdrawal, expectedWithdrawAmount);
    }

    function testWithdrawRevertsIfAmountIsZero() public UserBorrowedAndRepaidDebt {
        uint256 zeroAmountWithdraw = 0;
        vm.startPrank(user);
        vm.expectRevert(Errors.AmountNeedsMoreThanZero.selector);
        lendingCore.withdrawCollateral(tokens.weth, zeroAmountWithdraw);
        vm.stopPrank();
    }

    function testRevertsIfTokenIsNotAllowed() public UserBorrowedAndRepaidDebt {
        // Create a new random ERC20 token
        ERC20Mock dogToken = new ERC20Mock("DOG", "DOG", user, 100e18);

        // Start impersonating our test user
        vm.startPrank(user);

        // Expect revert with TokenNotAllowed error when trying to borrow unapproved token
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotAllowed.selector, address(dogToken)));
        // Attempt to withdraw unapproved token  (this should fail)
        lendingCore.withdrawCollateral(address(dogToken), DEPOSIT_AMOUNT);

        // Stop impersonating the user
        vm.stopPrank();
    }

    function testRevertsWhenWithdrawingFromZeroAddress() public {
        // Try to withdraw from address(0)
        vm.startPrank(address(0));
        vm.expectRevert(Errors.ZeroAddressNotAllowed.selector);
        lendingCore.withdrawCollateral(tokens.weth, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testRevertsIfUserHasNoCollateralDeposited() public {
        vm.startPrank(user);
        vm.expectRevert(Errors.Withdraw__UserHasNoCollateralDeposited.selector);
        lendingCore.withdrawCollateral(tokens.weth, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testRevertsIfUserWithdrawsMoreThanDeposited() public UserBorrowedAndRepaidDebt {
        uint256 moreThanDeposited = 20 ether;
        vm.startPrank(user);
        vm.expectRevert(Errors.Withdraw__UserDoesNotHaveThatManyTokens.selector);
        lendingCore.withdrawCollateral(tokens.weth, moreThanDeposited);
        vm.stopPrank();
    }

    function testDecreaseCollateralDepositedWhenWithdrawing() public UserBorrowedAndRepaidDebt {
        uint256 usersCollateralBalanceBeforeWithdraw = lendingCore.getCollateralBalanceOfUser(user, tokens.weth);
        vm.startPrank(user);

        lendingCore.withdrawCollateral(tokens.weth, DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 usersCollateralBalanceAfterWithdraw = lendingCore.getCollateralBalanceOfUser(user, tokens.weth);

        assert(usersCollateralBalanceAfterWithdraw < usersCollateralBalanceBeforeWithdraw);

        assertEq(usersCollateralBalanceAfterWithdraw, 0);
    }

    function testWithdrawsEmitEvent() public UserBorrowedAndRepaidDebt {
        vm.startPrank(user);
        vm.expectEmit(true, true, true, false, address(lendingCore));
        emit CollateralWithdrawn(tokens.weth, DEPOSIT_AMOUNT, user, user);
        lendingCore.withdrawCollateral(tokens.weth, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testWithdrawCollateralAfterRepayingDebt() public UserBorrowedAndRepaidDebt {
        uint256 expectedWithdrawAmount = 5 ether;
        uint256 balanceBeforeWithdrawal = ERC20Mock(tokens.weth).balanceOf(user);
        vm.startPrank(user);

        lendingCore.withdrawCollateral(tokens.weth, DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 balanceAfterWithdrawal = ERC20Mock(tokens.weth).balanceOf(user);

        assert(balanceAfterWithdrawal > balanceBeforeWithdrawal);
        assertEq(balanceAfterWithdrawal - balanceBeforeWithdrawal, expectedWithdrawAmount);
    }

    function testRevertsIfWithdrawFails() public {
        // Setup - Get the owner's address (msg.sender in this context)
        address owner = msg.sender;

        // Create new mock token contract that will fail transfers, deployed by owner
        vm.prank(owner);
        MockWithdraw mockWithdraw = new MockWithdraw();

        // Setup array with mock token as only allowed collateral
        tokenAddresses = [address(mockWithdraw)];
        // Setup array with tokens.weth price feed for the mock token
        feedAddresses = [priceFeeds.wethUsdPriceFeed];

        // Deploy new LendingCore instance with mock token as allowed collateral
        vm.prank(owner);
        LendingCore mockLendingCore = new LendingCore(
            tokenAddresses,
            feedAddresses,
            address(0), // Mock swap router
            address(0), // Mock automation registry
            0 // Mock upkeep ID
        );

        // Mint some mock tokens to our test user
        mockWithdraw.mint(user, DEPOSIT_AMOUNT);

        // Transfer ownership of mock token to LendingCore
        vm.prank(owner);
        mockWithdraw.transferOwnership(address(mockLendingCore));

        // Start impersonating our test user
        vm.startPrank(user);
        // Approve LendingCore to spend user's tokens
        mockWithdraw.approve(address(mockLendingCore), DEPOSIT_AMOUNT);

        // deposit collateral
        mockLendingCore.depositCollateral(address(mockWithdraw), DEPOSIT_AMOUNT);

        // Expect the transaction to revert with TransferFailed error
        vm.expectRevert(Errors.TransferFailed.selector);
        mockWithdraw.withdrawCollateral(tokens.link, LINK_AMOUNT_TO_BORROW);
        // Stop impersonating the user
        vm.stopPrank();
    }

    function testRevertsIfWithdrawBreaksHealthFactor() public LiquidLendingCore {
        uint256 amountToBorrow = 500e18;
        uint256 thisWithdrawAmountBreaksHealthFactor = 1 ether;
        uint256 expectedHealthFactor = 8e17; // 0.8 ether (health factor of 0.8)

        // Start impersonating the test user
        vm.startPrank(user);
        // Approve the lendingCore contract to spend user's tokens.weth
        // User deposits $10,000
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);

        // Deposit collateral and borrow tokens.link in one transaction
        // tokens.link is $10/token, user borrows 10, so thats $100 borrowed
        lendingCore.borrowFunds(tokens.link, amountToBorrow);
        // Stop impersonating the user
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.HealthFactor__BreaksHealthFactor.selector, expectedHealthFactor));
        lendingCore.withdrawCollateral(tokens.weth, thisWithdrawAmountBreaksHealthFactor);
        vm.stopPrank();
    }

    /////////////////////////
    //  Liquidation Tests  //
    /////////////////////////

    function testLiquidationsConstructor() public { }

    modifier UserCanBeLiquidatedWithNoBonus() {
        // Start impersonating the test user
        vm.startPrank(user);
        // Approve the lendingCore contract to spend user's tokens.weth
        // User deposits $10,000
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);

        // Deposit collateral and borrow tokens.link in one transaction
        // tokens.link is $10/token, user borrows 10, so thats $100 borrowed
        lendingCore.borrowFunds(tokens.link, LINK_AMOUNT_TO_BORROW);
        // Stop impersonating the user
        vm.stopPrank();

        // Set new ETH price to $20 (significant drop from original price)
        int256 wethUsdUpdatedPrice = 20e8; // 1 ETH = $20

        // we need $200 of collateral at all times if we have $100 of debt
        // Update the ETH/USD price feed with new lower price
        MockV3Aggregator(priceFeeds.wethUsdPriceFeed).updateAnswer(wethUsdUpdatedPrice);

        _;
    }

    function testLiquidationsRevertsIfAmountIsZero() public {
        vm.prank(liquidator);
        vm.expectRevert(Errors.AmountNeedsMoreThanZero.selector);
        lendingCore.liquidate(user, tokens.weth, tokens.link, 0);
    }

    function testLiquidationsRevertsIfCollateralTokenIsNotAllowed() public {
        // Create a new random ERC20 token
        ERC20Mock dogToken = new ERC20Mock("DOG", "DOG", user, 100e18);

        // Start impersonating our test user
        vm.startPrank(liquidator);

        // Expect revert with TokenNotAllowed error when trying to borrow unapproved token
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotAllowed.selector, address(dogToken)));
        // Attempt to liquidate user with unapproved token  (this should fail)
        lendingCore.liquidate(user, address(dogToken), tokens.link, DEPOSIT_AMOUNT);

        // Stop impersonating the user
        vm.stopPrank();
    }

    function testLiquidationsRevertsIfBorrowedTokenIsNotAllowed() public {
        // Create a new random ERC20 token
        ERC20Mock dogToken = new ERC20Mock("DOG", "DOG", user, 100e18);

        // Start impersonating our test user
        vm.startPrank(liquidator);

        // Expect revert with TokenNotAllowed error when trying to borrow unapproved token
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotAllowed.selector, address(dogToken)));
        // Attempt to liquidate user with unapproved token  (this should fail)
        lendingCore.liquidate(user, tokens.weth, address(dogToken), DEPOSIT_AMOUNT);

        // Stop impersonating the user
        vm.stopPrank();
    }

    function testLiquidationRevertsIfUserIsZeroAddress() public {
        vm.prank(liquidator);
        vm.expectRevert(Errors.ZeroAddressNotAllowed.selector);
        lendingCore.liquidate(address(0), tokens.weth, tokens.link, DEPOSIT_AMOUNT);
    }

    function testLiquidationRevertsIfUserSelfLiquidates() public {
        vm.prank(user);
        vm.expectRevert(Errors.Liquidations__CantLiquidateSelf.selector);
        lendingCore.liquidate(user, tokens.weth, tokens.link, DEPOSIT_AMOUNT);
    }

    function testLiquidationRevertsIfUserHasNotBorrowedToken() public {
        vm.prank(liquidator);
        vm.expectRevert(Errors.Liquidation__UserHasNotBorrowedToken.selector);
        lendingCore.liquidate(user, tokens.weth, tokens.link, DEPOSIT_AMOUNT);
    }

    function testLiquidationRevertsIfDebtAmountPaidExceedsCollateralAmount() public UserCanBeLiquidatedWithNoBonus {
        uint256 tooMuchToLiquidate = 20e18;
        vm.prank(liquidator);
        vm.expectRevert(Errors.Liquidations__DebtAmountPaidExceedsBorrowedAmount.selector);
        lendingCore.liquidate(user, tokens.weth, tokens.link, tooMuchToLiquidate);
    }

    function testLiquidationRevertsIfLiquidatorDoesNothaveEnoughTokens() public LiquidLendingCore {
        uint256 tooMuchForLiquidator = 100e18;
        // Start impersonating the test user
        vm.startPrank(user);
        // Approve the lendingCore contract to spend user's tokens.weth
        // User deposits $10,000
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);

        // Deposit collateral and borrow tokens.link in one transaction
        // tokens.link is $10/token, user borrows 10, so thats $100 borrowed
        lendingCore.borrowFunds(tokens.link, tooMuchForLiquidator);
        // Stop impersonating the user
        vm.stopPrank();

        vm.prank(liquidator);
        vm.expectRevert(Errors.Liquidations__InsufficientBalanceToLiquidate.selector);
        lendingCore.liquidate(user, tokens.weth, tokens.link, tooMuchForLiquidator);
    }

    function testLiquidationRevertsIfHealthFactorIsAboveOne() public UserDepositedAndBorrowedLink {
        vm.prank(liquidator);
        vm.expectRevert(Errors.Liquidations__HealthFactorIsHealthy.selector);
        lendingCore.liquidate(user, tokens.weth, tokens.link, DEPOSIT_AMOUNT);
    }

    modifier UserCanBeLiquidatedWithBonus() {
        ERC20Mock(tokens.link).mint(liquidator, 5000e18);

        // Start impersonating the test user
        vm.startPrank(user);
        // Approve the lendingCore contract to spend user's tokens.weth
        // User deposits $10,000
        ERC20Mock(tokens.weth).approve(address(lendingCore), DEPOSIT_AMOUNT);

        lendingCore.depositCollateral(tokens.weth, DEPOSIT_AMOUNT);

        // Deposit collateral and borrow tokens.link in one transaction
        // tokens.link is $10/token, user borrows 100, so thats $1000 borrowed
        lendingCore.borrowFunds(tokens.link, 100e18);
        // Stop impersonating the user
        vm.stopPrank();

        // Set new ETH price to $300 (significant drop from original price)
        int256 wethUsdUpdatedPrice = 300e8; // 1 ETH = $300

        // we need $200 of collateral at all times if we have $100 of debt
        // Update the ETH/USD price feed with new lower price
        MockV3Aggregator(priceFeeds.wethUsdPriceFeed).updateAnswer(wethUsdUpdatedPrice);

        uint256 liquidatorBalanceBefore = ERC20Mock(tokens.weth).balanceOf(liquidator);

        // user deposits are now worth 5 x 300 = 1500 USD
        _;
    }

    function testLiquidationPaysLiquidatorBonusFromSelectedCollateral()
        public
        LiquidLendingCore
        UserCanBeLiquidatedWithBonus
    {
        uint256 liquidatorBalanceBefore = ERC20Mock(tokens.weth).balanceOf(liquidator);
        uint256 expectedDebtAmountToPay = 100e18;
        uint256 expectedBonus = lendingCore.getTokenAmountFromUsd(tokens.weth, lendingCore.getUsdValue(tokens.link, 110e18));
        vm.startPrank(liquidator);
        ERC20Mock(tokens.link).approve(address(lendingCore), expectedDebtAmountToPay);
        lendingCore.liquidate(user, tokens.weth, tokens.link, expectedDebtAmountToPay);
        vm.stopPrank();

        uint256 liquidatorBalanceAfter = ERC20Mock(tokens.weth).balanceOf(liquidator);

        uint256 actualBonus = liquidatorBalanceAfter - liquidatorBalanceBefore;

        assertEq(actualBonus, expectedBonus);
    }

    function testLiquidationPaysLiquidatorBonusFromAllCollaterals() public UserCanBeLiquidatedWithNoBonus {
        uint256 liquidatorBalanceBefore = ERC20Mock(tokens.weth).balanceOf(liquidator);
        uint256 expectedDebtAmountToPay = 100e18;
        uint256 expectedBonus = lendingCore.getTokenAmountFromUsd(tokens.weth, lendingCore.getUsdValue(tokens.link, 110e18));
        vm.startPrank(liquidator);
        ERC20Mock(tokens.link).approve(address(lendingCore), expectedDebtAmountToPay);
        lendingCore.liquidate(user, tokens.weth, tokens.link, expectedDebtAmountToPay);
        vm.stopPrank();
        uint256 liquidatorBalanceAfter = ERC20Mock(tokens.weth).balanceOf(liquidator);

        uint256 actualBonus = liquidatorBalanceAfter - liquidatorBalanceBefore;

        assertEq(actualBonus, expectedBonus);
    } // we are here

    function testLiquidationCompletedByProtocolWithBonus() public { }

    function testLiquidationCompletedByProtocolWithNoBonus() public { }

    function testLiquidationByLiquidatorRevertsIfNoBonusAvailable() public { }

    function testLiquidationEmitsEvent() public { }

    function testLiquidationRevertsIfTransferFails() public { }

    function testLiquidationDecreasesUsersBorrowedAmount() public { }

    function testLiquidationDecreasesUsersCollateral() public { }

    function testLiquidationRevertsIfEndingHealthFactorIsWorseThanStarting() public { }

    function testLiquidationRevertsLiquidationBreaksHealthFactor() public UserCanBeLiquidatedWithNoBonus {
        uint256 expectedHealthFactor = 5e16;

        vm.startPrank(liquidator);

        // Approve tokens.link for liquidation
        ERC20Mock(tokens.link).approve(address(lendingCore), 9e18);

        // This reverts because liquidating 9 tokens.link would leave user with:
        // - 0.05 tokens.weth ($1 at $20/ETH) as collateral
        // - 1 tokens.link ($10) still borrowed
        // Making health factor = 0.05 which is < 1
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.HealthFactor__BreaksHealthFactor.selector,
                expectedHealthFactor // 0.05
            )
        );
        lendingCore.liquidate(user, tokens.weth, tokens.link, 9e18);

        vm.stopPrank();
    }

    function testIfBonusIsLessThanFivePercentProtocolAutomaticallyLiquidates() public { }

    /////////////////////
    //  LendingCore Tests  //
    ///////////////////

    /**
     * @notice Tests that the constructor properly initializes tokens and their price feeds
     * @dev This test verifies:
     * 1. The correct number of tokens are initialized
     * 2. Each token is properly mapped to its corresponding price feed
     * 3. All three tokens (tokens.weth, tokens.wbtc, tokens.link) are registered with correct price feeds
     * Test sequence:
     * 1. Get array of allowed tokens
     * 2. Verify array length
     * 3. For each token, verify its price feed mapping
     */
    function testLendingCoreConstructor() public view {
        // Create new arrays for tokens and price feeds
        address[] memory testTokens = new address[](3);
        testTokens[0] = tokens.weth;
        testTokens[1] = tokens.wbtc;
        testTokens[2] = tokens.link;

        address[] memory testFeeds = new address[](3);
        testFeeds[0] = priceFeeds.wethUsdPriceFeed;
        testFeeds[1] = priceFeeds.wbtcUsdPriceFeed;
        testFeeds[2] = priceFeeds.linkUsdPriceFeed;

        // Verify initialization
        address[] memory allowedTokens = lendingCore.getAllowedTokens();
        assertEq(allowedTokens.length, 3, "Should have 3 allowed tokens");
        assertEq(allowedTokens[0], tokens.weth, "First token should be tokens.weth");
        assertEq(allowedTokens[1], tokens.wbtc, "Second token should be tokens.wbtc");
        assertEq(allowedTokens[2], tokens.link, "Third token should be tokens.link");

        // Verify price feed mappings
        assertEq(lendingCore.getCollateralTokenPriceFeed(tokens.weth), priceFeeds.wethUsdPriceFeed, "tokens.weth price feed mismatch");
        assertEq(lendingCore.getCollateralTokenPriceFeed(tokens.wbtc), priceFeeds.wbtcUsdPriceFeed, "tokens.wbtc price feed mismatch");
        assertEq(lendingCore.getCollateralTokenPriceFeed(tokens.link), priceFeeds.linkUsdPriceFeed, "tokens.link price feed mismatch");
    }
}
