//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DeployADC} from "../../script/DeployADC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ADCEngine} from "../../src/ADCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/contracts/mocks/ERC20Mock.sol";

contract ADCEngineTest is Test {
    DeployADC deployer;
    DecentralizedStableCoin adc;
    ADCEngine adce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;


    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployADC();
        (adc, adce, config) = deployer.run(); //return the different output of deployer...
        (ethUsdPriceFeed, btcUsdPriceFeed,weth, wbtc,) = config.activeNetworkConfig();
        
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////////////
    // Constructor Test ////////
    ////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(ADCEngine.ADCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength.selector);
        new ADCEngine(tokenAddresses, priceFeedAddresses, address(adc));
    }


    //////////////////////
    // Price Test ////////
    //////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        //15e18 * 2000/ETH = 30000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = adce.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = adce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    ///////////////////////////////////
    // Deposit Collateral Test ////////
    ///////////////////////////////////

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(adce), AMOUNT_COLLATERAL);
        vm.expectRevert(ADCEngine.ADCEngine__NeedsMoreThanZero.selector);
        adce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    
    function testRevertWithUnapprovedCollateral() public{
        ERC20Mock RandToken = new ERC20Mock("RandToken", "RT", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(ADCEngine.ADCEngine__NotAllowedToken.selector);
        adce.depositCollateral(address(RandToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    function testCanDepositCollateralAndEmitCollateralDeposited() public 
    {               
        bytes32 expected = keccak256("CollateralDeposited(address,address,uint256)");

        vm.startPrank(USER);   
        ERC20Mock(weth).approve(address(adce), AMOUNT_COLLATERAL);
        vm.recordLogs();    
        adce.depositCollateral(weth, AMOUNT_COLLATERAL);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        vm.stopPrank();        
        assertEq(entries[0].topics.length, 4, "requires name function and 3 indexed parameters");
        assertEq(entries[0].topics[0], expected, "topic 0 should be the event signature");
        assertEq(entries[0].emitter, address(adce), "emitter should be the adce address");
        assertEq(address(uint160(uint256(entries[0].topics[1]))), address(USER), "topic 1 should be the user address");
        assertEq(address(uint160(uint256(entries[0].topics[2]))), address(weth), "topic 2 should be the token address");
    }
    
    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(adce), AMOUNT_COLLATERAL);
        adce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }



    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral{
        (uint256 totalADCMinted, uint256 collateralValueInUsd) = adce.getAccountInformation(USER);

        uint256 expectedTotalADCMinted = 0;
        uint256 expectedDepositAmount = adce.getTokenAmountFromUsd(address(weth), collateralValueInUsd);
        assertEq(totalADCMinted, expectedTotalADCMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }



    //
}