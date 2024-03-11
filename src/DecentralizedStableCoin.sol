//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/*
 * @title DecentralizedStableCoin
 * @author Antoine Picot
 * Collateral: Exogenous (ETH, BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
*/

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error AntoineDecentralizedCoin__MustBeMoreThanZero();
    error AntoineDecentralizedCoin__BurnAmountExceedsBalance();
    error AntoineDecentralizedCoin__NotZeroAddress();

    constructor(address initialOwner) ERC20("AntoineDecentralizedCoin", "ADC") Ownable(initialOwner){}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amount <= 0) {
            revert AntoineDecentralizedCoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert AntoineDecentralizedCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert AntoineDecentralizedCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert AntoineDecentralizedCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
