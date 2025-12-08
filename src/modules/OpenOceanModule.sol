// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ISwapModule} from "../interfaces/ISwapModule.sol";
import {SwapModuleBase} from "./SwapModuleBase.sol";

/// @title OpenOceanModule
/// @notice Swap module implementation for OpenOcean DEX aggregator
/// @dev Executes swaps via OpenOcean's exchange contract.
///      Validates that swap calls target the configured exchange address.
///      Supports both ERC20-to-ERC20 and native ETH-to-ERC20 swaps.
///
///      Security: The exchange address is immutable and validated at deployment.
///      All swap calls must target this exact address or they will revert.
contract OpenOceanModule is SwapModuleBase {
    /// @notice The OpenOcean exchange contract address
    /// @dev Immutable to save gas and ensure swap target cannot be changed post-deployment
    address public immutable openOceanExchange;

    /// @notice Creates a new OpenOcean swap module
    /// @dev Constructor is payable to save ~200 gas on deployment.
    ///      Validates exchange address is non-zero.
    /// @param _openOceanExchange Address of the OpenOcean exchange contract on this chain
    /// @param _weth Address of the WETH contract on this chain (for native ETH swaps)
    constructor(
        address _openOceanExchange,
        address _weth
    ) payable SwapModuleBase(_weth) {
        require(_openOceanExchange != address(0), "Invalid exchange");
        openOceanExchange = _openOceanExchange;
    }

    /// @inheritdoc ISwapModule
    function swap(
        SwapParams calldata params
    ) external override returns (SwapResult memory result) {
        (bytes memory callData, address target) = _decodeSwapData(params.swapData);
        if (target != openOceanExchange) revert InvalidSwapTarget();

        uint256 inputBefore = SafeTransferLib.balanceOf(params.inputToken, address(this));
        uint256 outputBefore = SafeTransferLib.balanceOf(params.outputToken, address(this));

        _approveIfNeeded(params.inputToken, openOceanExchange, params.inputAmount);
        _executeSwap(callData);

        uint256 outputAfter = SafeTransferLib.balanceOf(params.outputToken, address(this));
        uint256 inputAfter = SafeTransferLib.balanceOf(params.inputToken, address(this));

        result.outputAmountReceived = outputAfter - outputBefore;
        result.inputAmountSpent = inputBefore - inputAfter;

        _validateResult(params, result);
        _transferOutput(params, result.outputAmountReceived);
        _refundExcessInput(params.inputToken, params.refundTo, inputAfter);
    }

    /// @inheritdoc ISwapModule
    function swapNative(
        SwapParams calldata params
    ) external payable override returns (SwapResult memory result) {
        if (params.inputToken != address(0)) revert InvalidNativeSwap();

        (bytes memory callData, address target) = _decodeSwapData(params.swapData);
        if (target != openOceanExchange) revert InvalidSwapTarget();

        weth.deposit{value: msg.value}();

        uint256 inputBefore = weth.balanceOf(address(this));
        uint256 outputBefore = SafeTransferLib.balanceOf(params.outputToken, address(this));

        _approveIfNeeded(address(weth), openOceanExchange, params.inputAmount);
        _executeSwap(callData);

        uint256 outputAfter = SafeTransferLib.balanceOf(params.outputToken, address(this));
        uint256 inputAfter = weth.balanceOf(address(this));

        result.outputAmountReceived = outputAfter - outputBefore;
        result.inputAmountSpent = inputBefore - inputAfter;

        _validateResult(params, result);
        _transferOutput(params, result.outputAmountReceived);
        _refundExcessNative(params.refundTo, inputAfter);
    }

    /// @dev Executes the swap call to OpenOcean exchange
    /// @param callData The encoded swap call data from the OpenOcean API
    ///        This should be obtained from OpenOcean's quote API and passed through unchanged
    function _executeSwap(bytes memory callData) internal {
        (bool success,) = openOceanExchange.call(callData);
        if (!success) _bubbleRevert();
    }
}
