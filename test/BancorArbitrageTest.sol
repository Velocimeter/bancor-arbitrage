// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import { Token } from "../contracts/token/Token.sol";
import { TokenLibrary } from "../contracts/token/TokenLibrary.sol";
import { AccessDenied, ZeroValue, InvalidAddress } from "../contracts/utility/Utils.sol";
import { TransparentUpgradeableProxyImmutable } from "../contracts/utility/TransparentUpgradeableProxyImmutable.sol";
import { Utilities } from "./Utilities.t.sol";
import { BancorArbitrage } from "../contracts/arbitrage/BancorArbitrage.sol";
import { MockExchanges } from "../contracts/helpers/MockExchanges.sol";
import { MockNetworkSettings } from "../contracts/helpers/MockNetworkSettings.sol";
import { TestBNT } from "../contracts/helpers/TestBNT.sol";
import { TestWETH } from "../contracts/helpers/TestWETH.sol";
import { IBancorNetworkV2 } from "../contracts/exchanges/interfaces/IBancorNetworkV2.sol";
import { IBancorNetwork, IFlashLoanRecipient } from "../contracts/exchanges/interfaces/IBancorNetwork.sol";
import { ICarbonController, TradeAction } from "../contracts/exchanges/interfaces/ICarbonController.sol";
import { INetworkSettings } from "../contracts/interfaces/INetworkSettings.sol";
import { PPM_RESOLUTION } from "../contracts/utility/Constants.sol";
import { TestERC20Token } from "../contracts/helpers/TestERC20Token.sol";

/* solhint-disable max-states-count */
contract BancorArbitrageTest is Test {
    using TokenLibrary for Token;

    Utilities private utils;
    BancorArbitrage private bancorArbitrage;
    TestBNT private bnt;
    TestWETH private weth;
    TestERC20Token private arbToken1;
    TestERC20Token private arbToken2;
    TestERC20Token private nonWhitelistedToken;
    MockExchanges private exchanges;
    MockNetworkSettings private networkSettings;
    ProxyAdmin private proxyAdmin;

    BancorArbitrage.Exchanges private exchangeStruct;

    address[] private whitelistedTokens;

    address payable[] private users;
    address payable private admin;
    address payable private burnerWallet;

    uint private constant BNT_VIRTUAL_BALANCE = 1;
    uint private constant BASE_TOKEN_VIRTUAL_BALANCE = 2;
    uint private constant MAX_SOURCE_AMOUNT = 100_000_000 ether;
    uint private constant DEADLINE = type(uint256).max;
    uint private constant AMOUNT = 1000 ether;
    uint private constant MIN_LIQUIDITY_FOR_TRADING = 1000 ether;
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint private constant FIRST_EXCHANGE_ID = 1;
    uint private constant LAST_EXCHANGE_ID = 6;

    enum ExchangeId {
        INVALID,
        BANCOR_V2,
        BANCOR_V3,
        UNISWAP_V2,
        UNISWAP_V3,
        SUSHISWAP,
        CARBON
    }

    BancorArbitrage.Rewards private arbitrageRewardsDefaults =
        BancorArbitrage.Rewards({ percentagePPM: 30000, maxAmount: 100 ether });

    BancorArbitrage.Rewards private arbitrageRewardsUpdated =
        BancorArbitrage.Rewards({ percentagePPM: 40000, maxAmount: 200 ether });

    // Events
    /**
     * @dev triggered after a successful arb is executed
     */
    event ArbitrageExecuted(
        address indexed caller,
        uint16[] exchangeIds,
        address[] tokenPath,
        uint256 sourceAmount,
        uint256 burnAmount,
        uint256 rewardAmount
    );

    /**
     * @dev triggered when the rewards settings are updated
     */
    event RewardsUpdated(
        uint32 prevPercentagePPM,
        uint32 newPercentagePPM,
        uint256 prevMaxAmount,
        uint256 newMaxAmount
    );

    /**
     * @dev triggered when a flash-loan is completed
     */
    event FlashLoanCompleted(Token indexed token, address indexed borrower, uint256 amount, uint256 feeAmount);

    /**
     * @dev emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev function to set up state before tests
    function setUp() public virtual {
        utils = new Utilities();
        // create 4 users
        users = utils.createUsers(4);
        admin = users[0];
        burnerWallet = users[3];

        // deploy contracts from admin
        vm.startPrank(admin);

        // deploy proxy admin
        proxyAdmin = new ProxyAdmin();
        // deploy BNT
        bnt = new TestBNT("Bancor Network Token", "BNT", 1_000_000_000 ether);
        // deploy WETH
        weth = new TestWETH();
        // deploy MockExchanges
        exchanges = new MockExchanges(IERC20(weth), address(bnt), 300 ether, true);
        // init exchanges struct
        exchangeStruct = getExchangeStruct(address(exchanges));
        // deploy MockNetworkSettings
        networkSettings = new MockNetworkSettings();
        // Deploy arbitrage contract
        bancorArbitrage = new BancorArbitrage(
            bnt,
            burnerWallet,
            exchangeStruct,
            INetworkSettings(address(networkSettings))
        );

        bytes memory selector = abi.encodeWithSelector(bancorArbitrage.initialize.selector);

        // deploy arb proxy
        address arbProxy = address(
            new TransparentUpgradeableProxyImmutable(address(bancorArbitrage), payable(address(proxyAdmin)), selector)
        );
        bancorArbitrage = BancorArbitrage(payable(arbProxy));

        // deploy test tokens
        arbToken1 = new TestERC20Token("TKN1", "TKN1", 1_000_000_000 ether);
        arbToken2 = new TestERC20Token("TKN2", "TKN2", 1_000_000_000 ether);
        nonWhitelistedToken = new TestERC20Token("TKN", "TKN", 1_000_000_000 ether);

        // send some tokens to exchange
        nonWhitelistedToken.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        arbToken1.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        arbToken2.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        bnt.transfer(address(exchanges), MAX_SOURCE_AMOUNT * 5);
        // send eth to exchange
        vm.deal(address(exchanges), MAX_SOURCE_AMOUNT);
        // send weth to exchange
        vm.deal(admin, MAX_SOURCE_AMOUNT);
        weth.deposit{ value: MAX_SOURCE_AMOUNT }();
        weth.transfer(address(exchanges), MAX_SOURCE_AMOUNT);

        // whitelist tokens for flashloan
        exchanges.addToWhitelist(address(bnt));
        exchanges.addToWhitelist(address(arbToken1));
        exchanges.addToWhitelist(address(arbToken2));
        exchanges.addToWhitelist(NATIVE_TOKEN_ADDRESS);
        // whitelist tokens in network settings
        networkSettings.addToWhitelist(address(bnt));
        networkSettings.addToWhitelist(address(arbToken1));
        networkSettings.addToWhitelist(address(arbToken2));
        networkSettings.addToWhitelist(NATIVE_TOKEN_ADDRESS);

        vm.stopPrank();
    }

    /**
     * @dev test should be able to initialize new implementation
     */
    function testShouldBeAbleToInitializeImpl() public {
        BancorArbitrage __bancorArbitrage = new BancorArbitrage(
            bnt,
            burnerWallet,
            exchangeStruct,
            INetworkSettings(address(networkSettings))
        );
        __bancorArbitrage.initialize();
    }

    /**
     * @dev test revert when deploying BancorArbitrage with an invalid BNT contract
     */
    function testShouldRevertWhenInitializingWithInvalidBNTContract() public {
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(
            IERC20(address(0)),
            burnerWallet,
            exchangeStruct,
            INetworkSettings(address(networkSettings))
        );
    }

    /**
     * @dev test revert when deploying BancorArbitrage with an invalid burner wallet
     */
    function testShouldRevertWhenInitializingWithInvalidBurnerWallet() public {
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(bnt, address(0), exchangeStruct, INetworkSettings(address(networkSettings)));
    }

    /**
     * @dev test revert when deploying BancorArbitrage with an invalid Bancor V2 contract
     */
    function testShouldRevertWhenInitializingWithInvalidBancorV2Contract() public {
        exchangeStruct.bancorNetworkV2 = IBancorNetworkV2(address(0));
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(bnt, burnerWallet, exchangeStruct, INetworkSettings(address(networkSettings)));
    }

    /**
     * @dev test revert when deploying BancorArbitrage with an invalid Bancor V3 contract
     */
    function testShouldRevertWhenInitializingWithInvalidBancorV3Contract() public {
        exchangeStruct.bancorNetworkV3 = IBancorNetwork(address(0));
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(bnt, burnerWallet, exchangeStruct, INetworkSettings(address(networkSettings)));
    }

    /**
     * @dev test revert when deploying BancorArbitrage with an invalid Uni V2 router
     */
    function testShouldRevertWhenInitializingWithInvalidUniV2Router() public {
        exchangeStruct.uniV2Router = IUniswapV2Router02(address(0));
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(bnt, burnerWallet, exchangeStruct, INetworkSettings(address(networkSettings)));
    }

    /**
     * @dev test revert when deploying BancorArbitrage with an invalid Uni V3 router
     */
    function testShouldRevertWhenInitializingWithInvalidUniV3Router() public {
        exchangeStruct.uniV3Router = ISwapRouter(address(0));
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(bnt, burnerWallet, exchangeStruct, INetworkSettings(address(networkSettings)));
    }

    /**
     * @dev test revert when deploying BancorArbitrage with an invalid Sushiswap router
     */
    function testShouldRevertWhenInitializingWithInvalidSushiswapRouter() public {
        exchangeStruct.sushiswapRouter = IUniswapV2Router02(address(0));
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(bnt, burnerWallet, exchangeStruct, INetworkSettings(address(networkSettings)));
    }

    /**
     * @dev test revert when deploying BancorArbitrage with an invalid CarbonController contract
     */
    function testShouldRevertWhenInitializingWithInvalidCarbonControllerContract() public {
        exchangeStruct.carbonController = ICarbonController(address(0));
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(bnt, burnerWallet, exchangeStruct, INetworkSettings(address(networkSettings)));
    }

    /**
     * @dev test revert when deploying BancorArbitrage with an invalid NetworkSettings contract
     */
    function testShouldRevertWhenInitializingWithInvalidNetworkSettings() public {
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(bnt, burnerWallet, exchangeStruct, INetworkSettings(address(0)));
    }

    function testShouldBeInitialized() public {
        uint version = bancorArbitrage.version();
        assertEq(version, 3);
    }

    /// --- Reward tests --- ///

    /**
     * @dev test reverting when attempting to set rewards from non-admin address
     */
    function testShouldRevertWhenSettingRewardsFromNonAdmin() public {
        vm.prank(users[1]);
        vm.expectRevert(AccessDenied.selector);
        bancorArbitrage.setRewards(arbitrageRewardsUpdated);
    }

    /**
     * @dev test that set rewards shouldn't emit the RewardsUpdated event
     * @dev testFail is a test which expects an assertion to fail
     */
    function testFailShouldIgnoreSettingSameArbRewardsSettings() public {
        vm.prank(admin);
        // this assertion will fail
        vm.expectEmit(false, false, false, false);
        emit RewardsUpdated(0, 0, 0, 0);
        bancorArbitrage.setRewards(arbitrageRewardsDefaults);
    }

    /**
     * @dev test that admin should be able to set rewards settings
     */
    function testShouldBeAbleToSetArbRewardsSettings() public {
        vm.startPrank(admin);
        bancorArbitrage.setRewards(arbitrageRewardsDefaults);
        BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();
        assertEq(rewards.percentagePPM, 100_000);

        vm.expectEmit(true, true, true, true);
        emit RewardsUpdated(
            arbitrageRewardsUpdated.percentagePPM,
            arbitrageRewardsUpdated.percentagePPM,
            arbitrageRewardsDefaults.maxAmount,
            arbitrageRewardsUpdated.maxAmount
        );
        bancorArbitrage.setRewards(arbitrageRewardsUpdated);

        rewards = bancorArbitrage.rewards();
        assertEq(rewards.percentagePPM, 40_000);
        vm.stopPrank();
    }

    /// --- Distribution and burn tests --- ///

    /**
     * @dev test reward distribution and burn on arbitrage execution
     * @dev test with different flashloan tokens
     */
    function testShouldCorrectlyDistributeRewardsAndBurnTokens() public {
        vm.startPrank(admin);
        BancorArbitrage.Route[] memory routes = getRoutes();
        address[4] memory tokens = [address(arbToken1), address(arbToken2), NATIVE_TOKEN_ADDRESS, address(bnt)];
        // try different flashloan tokens
        for (uint i = 0; i < 4; ++i) {
            // final route token must be the flashloan token
            routes[2].targetToken = Token(tokens[i]);
            routes[2].customAddress = tokens[i];
            // first target token is arbToken1, so if we take flashloan in it, change it
            address firstTargetToken;
            if (tokens[i] == address(arbToken1)) {
                firstTargetToken = NATIVE_TOKEN_ADDRESS;
            } else {
                firstTargetToken = address(arbToken1);
            }
            routes[0].targetToken = Token(firstTargetToken);
            routes[0].customAddress = firstTargetToken;

            // each hop through the route from MockExchanges adds 300e18 tokens to the output
            // so 3 hops = 3 * 300e18 = 900 BNT tokens more than start
            // if we take a flashloan in a token other than BNT, we make one more swap to BNT, making the hops 4 in total
            // so with 0 flashloan fees, when we repay the flashloan, we have 900 or 1200 BNT tokens as totalRewards

            uint hopCount = tokens[i] == address(bnt) ? 3 : 4;
            uint totalRewards = 300e18 * hopCount;

            bancorArbitrage.setRewards(arbitrageRewardsUpdated);

            BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();

            uint expectedUserReward = (totalRewards * rewards.percentagePPM) / PPM_RESOLUTION;
            uint expectedBntBurnt = totalRewards - expectedUserReward;

            uint16[3] memory _exchangeIds = [
                uint16(ExchangeId.BANCOR_V2),
                uint16(ExchangeId.SUSHISWAP),
                uint16(ExchangeId.BANCOR_V2)
            ];
            address[4] memory _tokenPath = [tokens[i], firstTargetToken, address(arbToken2), tokens[i]];
            uint16[] memory exchangeIds = new uint16[](3);
            address[] memory tokenPath = new address[](4);
            for (uint j = 0; j < 3; ++j) {
                exchangeIds[j] = _exchangeIds[j];
                tokenPath[j] = _tokenPath[j];
            }
            tokenPath[3] = _tokenPath[3];

            vm.expectEmit(true, true, true, true);
            emit ArbitrageExecuted(admin, exchangeIds, tokenPath, AMOUNT, expectedBntBurnt, expectedUserReward);
            bancorArbitrage.execute(routes, Token(tokens[i]), AMOUNT);
        }
    }

    /**
     * @dev test reward distribution if the rewards exceed the max set rewards
     * @dev test with different flashloan tokens
     */
    function testShouldCorrectlyDistributeRewardsToCallerIfExceedingMaxRewards() public {
        vm.startPrank(admin);
        BancorArbitrage.Route[] memory routes = getRoutes();
        address[4] memory tokens = [address(arbToken1), address(arbToken2), NATIVE_TOKEN_ADDRESS, address(bnt)];
        // try different flashloan tokens
        for (uint i = 0; i < 4; ++i) {
            // final route token must be the flashloan token
            routes[2].targetToken = Token(tokens[i]);
            routes[2].customAddress = tokens[i];
            // first target token is arbToken1, so if we take flashloan in it, change it
            address firstTargetToken;
            if (tokens[i] == address(arbToken1)) {
                firstTargetToken = NATIVE_TOKEN_ADDRESS;
            } else {
                firstTargetToken = address(arbToken1);
            }
            routes[0].targetToken = Token(firstTargetToken);
            routes[0].customAddress = firstTargetToken;

            // each hop through the route from MockExchanges adds 300e18 tokens to the output
            // so 3 hops = 3 * 300e18 = 900 BNT tokens more than start
            // if we take a flashloan in a token other than BNT, we make one more swap to BNT, making the hops 4 in total
            // so with 0 flashloan fees, when we repay the flashloan, we have 900 or 1200 BNT tokens as totalRewards

            uint hopCount = tokens[i] == address(bnt) ? 3 : 4;
            uint totalRewards = 300e18 * hopCount;

            // set rewards maxAmount to 100
            BancorArbitrage.Rewards memory newRewards = BancorArbitrage.Rewards({
                percentagePPM: 40000,
                maxAmount: 100
            });

            bancorArbitrage.setRewards(newRewards);

            BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();

            // calculate expected user rewards based on total rewards and percentagePPM
            uint expectedUserReward = (totalRewards * rewards.percentagePPM) / PPM_RESOLUTION;

            // check we have exceeded the max reward amount
            assertGt(expectedUserReward, rewards.maxAmount);

            // update the expected user reward
            expectedUserReward = rewards.maxAmount;

            uint expectedBurn = totalRewards - expectedUserReward;

            uint16[3] memory _exchangeIds = [
                uint16(ExchangeId.BANCOR_V2),
                uint16(ExchangeId.SUSHISWAP),
                uint16(ExchangeId.BANCOR_V2)
            ];
            address[4] memory _tokenPath = [tokens[i], firstTargetToken, address(arbToken2), tokens[i]];
            uint16[] memory exchangeIds = new uint16[](3);
            address[] memory tokenPath = new address[](4);
            for (uint j = 0; j < 3; ++j) {
                exchangeIds[j] = _exchangeIds[j];
                tokenPath[j] = _tokenPath[j];
            }
            tokenPath[3] = _tokenPath[3];

            vm.expectEmit(true, true, true, true);
            emit ArbitrageExecuted(admin, exchangeIds, tokenPath, AMOUNT, expectedBurn, expectedUserReward);
            bancorArbitrage.execute(routes, Token(address(tokens[i])), AMOUNT);
        }
    }

    /// --- Flashloan tests --- ///

    /**
     * @dev test that onFlashloan cannot be called directly
     */
    function testShouldntBeAbleToCallOnFlashloanDirectly() public {
        vm.expectRevert(BancorArbitrage.InvalidFlashLoanCaller.selector);
        bancorArbitrage.onFlashLoan(address(bancorArbitrage), IERC20(address(bnt)), 1, 0, "0x");
    }

    /**
     * @dev test correct obtaining and repayment of flashloan
     */
    function testShouldCorrectlyObtainAndRepayFlashloan() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        vm.expectEmit(true, true, true, true);
        emit FlashLoanCompleted(Token(address(bnt)), address(bancorArbitrage), AMOUNT, 0);
        bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test should revert if flashloan cannot be obtained
     */
    function testShouldRevertIfFlashloanCannotBeObtained() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        vm.expectRevert();
        bancorArbitrage.execute(routes, Token(address(bnt)), type(uint256).max);
    }

    /// --- Trade tests --- ///

    /**
     * @dev test that trade attempt if deadline is > block.timestamp reverts
     */
    function testShouldRevertIfDeadlineIsReached() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        // move block.timestamp forward by 1000 sec
        skip(1000);
        // set deadline to 1
        routes[0].deadline = 1;
        routes[1].deadline = 1;
        routes[2].deadline = 1;
        vm.expectRevert();
        bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test that trade attempt reverts if exchange id is not supported
     */
    function testShouldRevertIfExchangeIdIsNotSupported() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        routes[0].exchangeId = 0;
        vm.expectRevert(BancorArbitrage.InvalidExchangeId.selector);
        bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test that trade attempt with invalid route length
     */
    function testShouldRevertIfRouteLengthIsInvalid() public {
        // attempt to route through 11 exchanges
        BancorArbitrage.Route[] memory longRoute = new BancorArbitrage.Route[](11);

        vm.expectRevert(BancorArbitrage.InvalidRouteLength.selector);
        bancorArbitrage.execute(longRoute, Token(address(bnt)), AMOUNT);
        // attempt to route through 0 exchanges
        BancorArbitrage.Route[] memory emptyRoute = new BancorArbitrage.Route[](0);
        vm.expectRevert(BancorArbitrage.InvalidRouteLength.selector);
        bancorArbitrage.execute(emptyRoute, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test attempting to trade with more than exchange's balance reverts
     */
    function testShouldRevertIfExchangeDoesntHaveEnoughBalance() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        bancorArbitrage.execute(routes, Token(address(bnt)), MAX_SOURCE_AMOUNT * 2);
    }

    /**
     * @dev test reverts if min target amount is greater than expected
     */
    function testShouldRevertIfMinTargetAmountIsGreaterThanExpected() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        routes[0].minTargetAmount = type(uint256).max;
        vm.expectRevert("InsufficientTargetAmount");
        bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test reverts if the output token of the arb isn't the flashloan token
     */
    function testShouldRevertIfOutputTokenIsntTheFlashloanToken() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        routes[2].targetToken = Token(address(arbToken2));
        routes[2].customAddress = address(arbToken2);
        address[3] memory tokens = [address(bnt), address(arbToken1), NATIVE_TOKEN_ADDRESS];
        for (uint i = 0; i < 3; ++i) {
            vm.expectRevert(BancorArbitrage.InvalidInitialAndFinalTokens.selector);
            bancorArbitrage.execute(routes, Token(tokens[i]), AMOUNT);
        }
    }

    /**
     * @dev test reverts if the flashloan token isn't whitelisted
     */
    function testShouldRevertIfFlashloanTokenIsntWhitelisted() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        // set last token to be the non-whitelisted token
        routes[2].targetToken = Token(address(nonWhitelistedToken));
        routes[2].customAddress = address(nonWhitelistedToken);
        vm.expectRevert(MockExchanges.NotWhitelisted.selector);
        // make arb with the non-whitelisted token
        bancorArbitrage.execute(routes, Token(address(nonWhitelistedToken)), AMOUNT);
    }

    /**
     * @dev test reverts if the path is invalid
     * @dev the test uses same input and output token for the second swap
     */
    function testShouldRevertIfThePathIsInvalid() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        routes[1].exchangeId = uint16(ExchangeId.BANCOR_V2);
        routes[1].targetToken = Token(address(arbToken1));
        routes[1].customAddress = address(arbToken1);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test trade approvals for erc-20 tokens for exchanges
     * @dev should approve max amount for trading on each first swap for token and exchange
     */
    function testShouldApproveERC20TokensForEachExchange(uint16 exchangeId) public {
        // bound to valid exchange ids
        exchangeId = uint16(bound(exchangeId, FIRST_EXCHANGE_ID, LAST_EXCHANGE_ID));
        address[] memory tokensToTrade = new address[](3);
        tokensToTrade[0] = address(arbToken1);
        tokensToTrade[1] = address(arbToken2);
        tokensToTrade[2] = NATIVE_TOKEN_ADDRESS;
        uint approveAmount = type(uint256).max;

        // test with all token combinations
        for (uint i = 0; i < 3; ++i) {
            for (uint j = 0; j < 3; ++j) {
                if (i == j) {
                    continue;
                }
                BancorArbitrage.Route[] memory routes = getRoutesCustomTokens(
                    exchangeId,
                    tokensToTrade[i],
                    tokensToTrade[j],
                    address(bnt),
                    500
                );
                uint allowance = arbToken1.allowance(address(bancorArbitrage), address(exchanges));
                if (allowance == 0) {
                    // expect arbToken1 to emit the approval event
                    vm.expectEmit(true, true, true, true, address(arbToken1));
                    emit Approval(address(bancorArbitrage), address(exchanges), approveAmount);
                }
                bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
            }
        }
    }

    /// --- Arbitrage tests --- ///

    /**
     * @dev test arbitrage executed event gets emitted
     */
    function testShouldEmitArbitrageExecutedOnSuccessfulArb() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        uint16[] memory exchangeIds = new uint16[](0);
        address[] memory tradePath = new address[](0);
        vm.expectEmit(false, false, false, false);
        emit ArbitrageExecuted(admin, exchangeIds, tradePath, AMOUNT, 0, 0);
        bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test that any address can execute arbs
     */
    function testAnyoneCanExecuteArbs(address user) public {
        // assume user is not proxy admin or 0x0 address
        vm.assume(user != address(proxyAdmin) && user != address(0));
        BancorArbitrage.Route[] memory routes = getRoutes();
        // impersonate user
        vm.prank(user);
        bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev fuzz test arbitrage execution
     * @dev go through all exchanges and use different amounts
     */
    function testArbitrage(uint16 exchangeId, uint arbAmount, uint fee) public {
        // limit arbAmount to AMOUNT
        vm.assume(arbAmount > 0 && arbAmount < AMOUNT);
        // test exchange ids 1 - 5 (w/o Carbon)
        exchangeId = uint16(bound(exchangeId, FIRST_EXCHANGE_ID, 5));
        address[] memory tokensToTrade = new address[](3);
        tokensToTrade[0] = address(arbToken1);
        tokensToTrade[1] = address(arbToken2);
        tokensToTrade[2] = NATIVE_TOKEN_ADDRESS;

        // test with all token combinations
        for (uint i = 0; i < 3; ++i) {
            for (uint j = 0; j < 3; ++j) {
                if (i == j) {
                    continue;
                }
                BancorArbitrage.Route[] memory routes = getRoutesCustomTokens(
                    exchangeId,
                    tokensToTrade[i],
                    tokensToTrade[j],
                    address(bnt),
                    fee
                );
                bancorArbitrage.execute(routes, Token(address(bnt)), arbAmount);
            }
        }
    }

    /**
     * @dev test arbitrages with different route length
     * @dev fuzz test 2 - 10 routes on any exchange with any amount
     */
    function testArbitrageWithDifferentRoutes(uint routeLength, uint16 exchangeId, uint arbAmount, uint fee) public {
        // bound route len from 2 to 10
        routeLength = bound(routeLength, 2, 10);
        // bound exchange id to valid exchange ids
        exchangeId = uint16(bound(exchangeId, FIRST_EXCHANGE_ID, LAST_EXCHANGE_ID));
        // bound arb amount from 1 to AMOUNT
        arbAmount = bound(arbAmount, 1, AMOUNT);
        // get routes
        BancorArbitrage.Route[] memory routes = getRoutesCustomLength(routeLength, exchangeId, fee, arbAmount);
        // trade
        bancorArbitrage.execute(routes, Token(address(bnt)), arbAmount);
    }

    /**
     * @dev fuzz test arbs on carbon
     * @dev use different arb amounts and 1 to 11 trade actions for the carbon arb
     */
    function testArbitrageOnCarbon(uint arbAmount, uint tradeActionCount) public {
        // bound arb amount from 1 to AMOUNT
        arbAmount = bound(arbAmount, 1, AMOUNT);
        BancorArbitrage.Route[] memory routes = getRoutesCarbon(
            address(arbToken1),
            address(arbToken2),
            arbAmount,
            tradeActionCount
        );
        bancorArbitrage.execute(routes, Token(address(bnt)), arbAmount);
    }

    /**
     * @dev test transferring leftover source tokens from the carbon trade to the burner wallet
     * @param arbAmount arb amount to test with
     * @param leftoverAmount amount of tokens left over after the carbon trade
     */
    function testShouldTransferLeftoverSourceTokensFromCarbonTrade(uint arbAmount, uint leftoverAmount) public {
        // bound arb amount from 1 to AMOUNT
        arbAmount = bound(arbAmount, 1, AMOUNT);
        // bound leftover amount from 1 to 300 units
        leftoverAmount = bound(leftoverAmount, 1, 300 ether);
        BancorArbitrage.Route[] memory routes = getRoutes();
        routes[1].exchangeId = uint16(ExchangeId.CARBON);
        uint sourceTokenAmountForCarbonTrade = arbAmount + 300 ether;
        // encode less tokens for the trade than the source token balance at this point in the arb
        routes[1].customData = getCarbonData(sourceTokenAmountForCarbonTrade - leftoverAmount);

        // get source token balance in the burner wallet before the trade
        uint sourceBalanceBefore = arbToken1.balanceOf(burnerWallet);

        // execute arb
        bancorArbitrage.execute(routes, Token(address(bnt)), arbAmount);

        // get source token balance in the burner wallet after the trade
        uint sourceBalanceAfter = arbToken1.balanceOf(burnerWallet);
        uint sourceBalanceTransferred = sourceBalanceAfter - sourceBalanceBefore;

        // assert that the entire leftover amount is transferred to the burner wallet
        assertEq(leftoverAmount, sourceBalanceTransferred);
        // assert that no source tokens are left in the arb contract
        assertEq(arbToken1.balanceOf(address(bancorArbitrage)), 0);
    }

    /**
     * @dev fuzz test arbitrage execution with flashloan token different from BNT
     * @dev go through all exchanges and use different amounts
     */
    function testArbitrageWithDifferentFlashloanTokens(uint16 exchangeId, uint arbAmount, uint fee) public {
        // limit arbAmount to AMOUNT
        vm.assume(arbAmount > 0 && arbAmount < AMOUNT);
        // test exchange ids 1 - 5 (w/o Carbon)
        exchangeId = uint16(bound(exchangeId, FIRST_EXCHANGE_ID, 5));
        address[] memory tokensToTrade = new address[](3);
        tokensToTrade[0] = address(arbToken1);
        tokensToTrade[1] = address(arbToken2);
        tokensToTrade[2] = NATIVE_TOKEN_ADDRESS;

        // test with all token combinations
        for (uint i = 0; i < 3; ++i) {
            for (uint j = 0; j < 3; ++j) {
                if (i == j) {
                    continue;
                }
                BancorArbitrage.Route[] memory routes = getRoutesCustomTokens(
                    exchangeId,
                    tokensToTrade[i],
                    tokensToTrade[j],
                    tokensToTrade[i],
                    fee
                );
                bancorArbitrage.execute(routes, Token(tokensToTrade[i]), arbAmount);
            }
        }
    }

    /**
     * @dev test that arb attempt with 0 amount should revert
     */
    function testShouldRevertArbWithZeroAmount() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        vm.expectRevert(ZeroValue.selector);
        bancorArbitrage.execute(routes, Token(address(bnt)), 0);
    }

    /**
     * @dev test that arb attempt on carbon with invalid trade data should revert
     */
    function testShouldRevertArbOnCarbonWithInvalidData(bytes memory data) public {
        BancorArbitrage.Route[] memory routes = getRoutesCustomTokens(
            uint16(ExchangeId.CARBON),
            address(arbToken1),
            address(arbToken2),
            address(bnt),
            500
        );
        routes[1].customData = data;
        vm.expectRevert();
        bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test that arb attempt on carbon with invalid trade data should revert
     */
    function testShouldRevertArbOnCarbonWithLargerThanUint128TargetAmount() public {
        BancorArbitrage.Route[] memory routes = getRoutesCustomTokens(
            uint16(ExchangeId.CARBON),
            address(arbToken1),
            address(arbToken2),
            address(bnt),
            500
        );
        routes[1].minTargetAmount = 2 ** 128;
        vm.expectRevert(BancorArbitrage.MinTargetAmountTooHigh.selector);
        bancorArbitrage.execute(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev get 3 routes for arb testing
     */
    function getRoutes() public view returns (BancorArbitrage.Route[] memory routes) {
        routes = new BancorArbitrage.Route[](3);

        routes[0] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(address(arbToken1)),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(arbToken1),
            customInt: 0,
            customData: ""
        });

        routes[1] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.SUSHISWAP),
            targetToken: Token(address(arbToken2)),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(arbToken2),
            customInt: 0,
            customData: ""
        });

        routes[2] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(address(bnt)),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(bnt),
            customInt: 0,
            customData: ""
        });
        return routes;
    }

    /**
     * @dev get 3 routes for arb testing with custom tokens and 2nd exchange id
     * @param exchangeId - which exchange to use for middle swap
     * @param token1 - first swapped token
     * @param token2 - second swapped token
     * @param token2 - flashloan token
     * @param fee - Uni V3 fee, can be 100, 500 or 3000
     */
    function getRoutesCustomTokens(
        uint16 exchangeId,
        address token1,
        address token2,
        address flashloanToken,
        uint fee
    ) public view returns (BancorArbitrage.Route[] memory routes) {
        routes = new BancorArbitrage.Route[](3);

        uint customFee = 0;
        // add custom fee bps for uni v3 - 100, 500 or 3000
        if (exchangeId == uint16(ExchangeId.UNISWAP_V3)) {
            uint16[3] memory fees = [100, 500, 3000];
            // get a random fee on each run
            uint feeIndex = bound(fee, 0, 2);
            // use 100, 500 or 3000
            customFee = fees[feeIndex];
        }
        bytes memory data = "";
        // add custom data for carbon
        if (exchangeId == uint16(ExchangeId.CARBON)) {
            TradeAction[] memory tradeActions = new TradeAction[](1);
            tradeActions[0] = TradeAction({ strategyId: 0, amount: uint128(AMOUNT + 300 ether) });
            data = abi.encode(tradeActions);
        }

        routes[0] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(token1),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token1,
            customInt: 0,
            customData: ""
        });

        routes[1] = BancorArbitrage.Route({
            exchangeId: exchangeId,
            targetToken: Token(token2),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token2,
            customInt: customFee,
            customData: data
        });

        routes[2] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(flashloanToken),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: flashloanToken,
            customInt: 0,
            customData: ""
        });
        return routes;
    }

    /**
     * @dev get several routes for arb testing with custom route length
     * @param routeLength - how many routes to generate
     * @param exchangeId - which exchange to perform swaps on
     * @param fee - Uni V3 fee, can be 100, 500 or 3000
     * @param arbAmount - initial arb amount
     */
    function getRoutesCustomLength(
        uint routeLength,
        uint16 exchangeId,
        uint fee,
        uint arbAmount
    ) public view returns (BancorArbitrage.Route[] memory routes) {
        routes = new BancorArbitrage.Route[](routeLength);

        uint customFee = 0;
        // add custom fee bps for uni v3 - 100, 500 or 3000
        if (exchangeId == uint16(ExchangeId.UNISWAP_V3)) {
            uint16[3] memory fees = [100, 500, 3000];
            // get a random fee on each run
            uint feeIndex = bound(fee, 0, 2);
            // use 100, 500 or 3000
            customFee = fees[feeIndex];
        }
        bytes memory data = "";
        uint currentAmount = arbAmount;

        address targetToken = address(arbToken1);

        // generate route for trading
        for (uint i = 0; i < routeLength; ++i) {
            if (i % 3 == 0) {
                targetToken = address(arbToken1);
            } else if (i % 3 == 1) {
                targetToken = address(arbToken2);
            } else {
                targetToken = NATIVE_TOKEN_ADDRESS;
            }
            data = getCarbonData(currentAmount);
            routes[i] = BancorArbitrage.Route({
                exchangeId: exchangeId,
                targetToken: Token(targetToken),
                minTargetAmount: 1,
                deadline: DEADLINE,
                customAddress: targetToken,
                customInt: customFee,
                customData: data
            });
            currentAmount += 300 ether;
        }
        // last token should be BNT
        routes[routeLength - 1].targetToken = Token(address(bnt));
        routes[routeLength - 1].customAddress = address(bnt);
        return routes;
    }

    /**
     * @dev get 3 routes for arb testing with custom tokens and 2nd exchange = carbon
     * @param token1 - first swapped token
     * @param token2 - second swapped token
     * @param tradeActionCount - count of individual trade actions passed to carbon trade
     */
    function getRoutesCarbon(
        address token1,
        address token2,
        uint arbAmount,
        uint tradeActionCount
    ) public view returns (BancorArbitrage.Route[] memory routes) {
        routes = new BancorArbitrage.Route[](3);

        // generate from 1 to 11 actions
        // each action will trade `amount / tradeActionCount`
        tradeActionCount = bound(tradeActionCount, 1, 11);
        TradeAction[] memory tradeActions = new TradeAction[](tradeActionCount + 1);
        // source amount at the point of carbon trade is arbAmount + _outputAmount = 300
        uint totalSourceAmount = arbAmount + 300 ether;
        for (uint i = 1; i <= tradeActionCount; ++i) {
            tradeActions[i] = TradeAction({ strategyId: i, amount: uint128(totalSourceAmount / tradeActionCount) });
        }
        // add remainder of the division to the last trade action
        // goal is for strategies sum to be exactly equal to the source amount
        tradeActions[tradeActionCount].amount += uint128(totalSourceAmount % tradeActionCount);
        bytes memory customData = abi.encode(tradeActions);

        routes[0] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(token1),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token1,
            customInt: 0,
            customData: ""
        });

        routes[1] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.CARBON),
            targetToken: Token(token2),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token2,
            customInt: 0,
            customData: customData
        });

        routes[2] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(address(bnt)),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(bnt),
            customInt: 0,
            customData: ""
        });
        return routes;
    }

    /**
     * @dev get custom data for trading on Carbon
     * @param amount the amount to be traded
     * @return data the encoded trading data
     */
    function getCarbonData(uint amount) public pure returns (bytes memory data) {
        TradeAction[] memory tradeActions = new TradeAction[](1);
        tradeActions[0] = TradeAction({ strategyId: 0, amount: uint128(amount) });
        data = abi.encode(tradeActions);
    }

    /**
     * @dev get exchange struct for initialization of the arb bot
     */
    function getExchangeStruct(address _exchanges) public pure returns (BancorArbitrage.Exchanges memory exchangeList) {
        exchangeList = BancorArbitrage.Exchanges({
            bancorNetworkV2: IBancorNetworkV2(_exchanges),
            bancorNetworkV3: IBancorNetwork(_exchanges),
            uniV2Router: IUniswapV2Router02(_exchanges),
            uniV3Router: ISwapRouter(_exchanges),
            sushiswapRouter: IUniswapV2Router02(_exchanges),
            carbonController: ICarbonController(_exchanges)
        });
    }
}
