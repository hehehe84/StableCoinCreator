//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title ADCEngine
 * @author Antoine Picot
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token = $1 peg
 * This stablecoin has the properties:
 * -Exogenous Collateral
 * -Dollar Pegged
 * -Algorithmically Stable
 *
 * It is similar to DAI if DAI has no governance, no fees, and was only backed by WETH and WBTC
 *
 * Our ADC should always be OverCollateralized. It should never have a value > of the value of all the collateral...
 *
 * @notice This contract handle all the logic for mining and reedeming ADC, as well as depositing & withdrawing collateral.
 * @notice This contract is based on MakerDAO DSS (DAI) system
 */
contract ADCEngine is ReentrancyGuard {
    ///////////////////
    // Errors//////////
    ///////////////////
    error ADCEngine__NeedsMoreThanZero();
    error ADCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
    error ADCEngine__NotAllowedToken();
    error ADCEngine__TransfertFailed();
    error ADCEngine__BreaksHealthFactor(uint256 healthFactor);
    error ADCEngine__MintFailed();
    error ADCEngine__HealthFactorOk();
    error ADCEngine__HealthFactorNotImproved();

    ///////////////////
    // State Variables/
    ///////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //10% bonus for liquidating a user

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountAdcMinted) private s_ADCMinted;
    address[] private s_collateralTokens;
    


    DecentralizedStableCoin private immutable i_adc;

    ///////////////////
    // Events   ///////
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address reedemedFrom, address reedemedTo, address indexed token, uint256 indexed amount);

    ///////////////////
    // Modifiers///////
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert ADCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert ADCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////
    // Functions///////
    ///////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address adcAddress) {
        //USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert ADCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
        }
        //For example ETH/USD, BTC/USD,...
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_adc = DecentralizedStableCoin(adcAddress);
    }

    ////////////////////////////
    // External Functions///////
    ////////////////////////////

    /**
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountCollateral The amount of decentralized stableCoin to Mint
     * @param amountAdcToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit the collateral and mint ADC in one transaction
     */

    function depositCollateralAndMintADC(
        address tokenCollateralAddress, 
        uint256 amountCollateral, 
        uint256 amountAdcToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintADC(amountAdcToMint);
    }

    /*
     * @notice follow CEI (Check Effect Interact)
     * @param tokenCollateralAddress The Address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success){
            revert ADCEngine__TransfertFailed();
        }

    }


    /* 
    * @param tokenCollateralAddress The Address of the token to redeem as collateral
    * @param amountCollateral The amount of collateral to redeem
    * @param amountAdcToBurn The amount of decentralized stablecoin to burn
    * this function burns ADC and redeems collateral in one transaction
    */
    function redeemCollateralForADC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountAdcToBurn) 
        external 
    {
        burnADC(amountAdcToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    //100$ => $20 DSC

    
    function redeemCollateral (address tokenCollateralAddress, uint256 amountCollateral) 
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * 1. Check if the collateral value > DSCAmount
     * @param amountAdcToMint the amount of stablecoin to mint
     * @notice
     */
    function mintADC(uint256 amountAdcToMint) public moreThanZero(amountAdcToMint) nonReentrant{
        s_ADCMinted[msg.sender]+=amountAdcToMint;
        // If they minted too much ($150 ADC, 100$ ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_adc.mint(msg.sender, amountAdcToMint);
        if(!minted) {
            revert ADCEngine__MintFailed();
        }
    }

    //No need to see if it break health factor
    function burnADC(uint256 amount) 
        public 
        moreThanZero(amount)
    {
        _burnADC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //Too see if it is useful
    }

    //liquidate is a function that will be called by a liquidator to liquidate a user
    //This hit when we are below the health factor (undercollateralized)
    //We will pay you to liquidate undercollateralized users

    /**
    * @param collateral The address of the collateral to liquidate
    * @param user The address of the user to liquidate (broken healthFactor) HealthFactor < MIN_HEALTH_FACTOR
    * @param debtToCover The amount of debt to burn in order to improve the health factor of a user
    * @notice You can partially liquidate a user
    * @notice You get a liquidation bonus for liquidating a user
    * @notice This function working assume the protocol will be roughly 200% overcollateralized in order for this to work.
    * @notice we should be carefull the protocol is <=100% overcollateralized. this does not incentivize people to liquidate
    */
    function liquidate(address collateral, address user, uint256 debtToCover) 
        external 
        moreThanZero(debtToCover)
        nonReentrant()
    {
        //Is the user liquidatable
        uint256 startingUserHealthFacor = _healthFactor(user);
        if(startingUserHealthFacor >= MIN_HEALTH_FACTOR) {
            revert ADCEngine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //Giving them 10% Bonus !
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        //We now burn ADC
        _burnADC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFacor) {
            revert ADCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}



    ////////////////////////////////////
    // Private/Internal Functions///////
    ////////////////////////////////////

    /**
     * @dev low-level internal function, do not call unless the function calling is checking for healthFactor being broken...
     */
    function _burnADC(uint256 amountAcdToBurn, address onBehalfOf, address acdFrom) private {
        s_ADCMinted[onBehalfOf] -= amountAcdToBurn;
        bool success = i_adc.transferFrom(acdFrom, address(this), amountAcdToBurn);
        if(!success){
            revert ADCEngine__TransfertFailed();
        }
        i_adc.burn(amountAcdToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success){
            revert ADCEngine__TransfertFailed();
        }
    }

    function _getAccountInformation(address user) private view returns(uint256 totalADCMinted, uint256 collateralValueInUsd) {
        totalADCMinted = s_ADCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUSD(user);
    }
    /**
     * Return how close to liquidation a user is
     * If a user goes below 1, they can get liquidated
     */

    function _healthFactor(address user) private view returns(uint256) {
        (uint256 totalADCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForTreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForTreshold * PRECISION) / totalADCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR) {
            revert ADCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////////////////////
    // Public & External View Functions///////
    //////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price)*ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValueInUSD(address user) public view returns(uint256 totalCollateralValueInUSD) {
        for (uint256 i=0; i < s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD += getUsdValue(token, amount);
        }
        return totalCollateralValueInUSD;
    }

    //1 ETH = 1000$
    // The returned value from CL is => 1000 * 1e8
    // Amount (in Wei) => 1ETH = 1e18
    function getUsdValue(address token, uint256 amount) public view returns(uint256){  //To TEST !!!
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION);
    }
    function getAccountInformation(address user) public view returns(uint256 totalADCMinted, uint256 collateralValueInUsd) {
        (totalADCMinted, collateralValueInUsd) =_getAccountInformation(user);
    }
}
