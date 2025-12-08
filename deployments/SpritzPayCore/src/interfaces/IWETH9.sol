// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IWETH9
/// @notice Interface for Wrapped ETH (WETH) contract
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}
