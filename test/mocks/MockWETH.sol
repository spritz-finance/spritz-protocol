// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {ERC20Mock} from "../../src/test/ERC20Mock.sol";

/// @title MockWETH
/// @notice Mock WETH contract for testing native ETH swaps
contract MockWETH is ERC20Mock, IWETH9 {
    function deposit() external payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function balanceOf(address account) public view override(ERC20, IWETH9) returns (uint256) {
        return super.balanceOf(account);
    }

    function approve(address spender, uint256 amount) public override(ERC20, IWETH9) returns (bool) {
        return super.approve(spender, amount);
    }

    function transfer(address to, uint256 amount) public override(ERC20, IWETH9) returns (bool) {
        return super.transfer(to, amount);
    }

    receive() external payable {}
}
