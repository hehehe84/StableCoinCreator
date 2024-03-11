// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ADCEngine} from "../src/ADCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployADC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;
    function run() external returns(DecentralizedStableCoin, ADCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) = config.activeNetworkConfig();

        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        DecentralizedStableCoin adc = new DecentralizedStableCoin(address(this));
        ADCEngine engine = new ADCEngine(
            tokenAddresses, 
            priceFeedAddresses, 
            address(adc)
        );

        vm.stopBroadcast();
        return(adc, engine, config);
    }
}