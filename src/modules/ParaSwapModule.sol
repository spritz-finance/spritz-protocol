// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ISwapModule} from "../interfaces/ISwapModule.sol";
import {SwapModuleBase} from "./SwapModuleBase.sol";
import {IParaSwapAugustus, IParaSwapAugustusRegistry} from "../interfaces/IParaSwap.sol";

/// @title ParaSwapModule
/// @notice Swap module implementation for ParaSwap DEX aggregator
/// @dev Executes swaps via ParaSwap's Augustus router with registry validation.
///      Supports both ERC20-to-ERC20 and native ETH-to-ERC20 swaps.
///
///      Security: Uses ParaSwap's Augustus registry to validate that swap targets
///      are legitimate ParaSwap routers. This allows ParaSwap to upgrade their
///      router while maintaining security - only registry-approved routers are accepted.
///
///      Token approvals go to the Augustus router's TokenTransferProxy, not the router
///      itself, following ParaSwap's security architecture.
contract ParaSwapModule is SwapModuleBase {
    /// @notice The ParaSwap Augustus registry for validating routers
    /// @dev Used to verify that swap targets are legitimate ParaSwap Augustus routers
    IParaSwapAugustusRegistry public immutable registry;

    /// @notice Creates a new ParaSwap swap module
    /// @dev Constructor is payable to save ~200 gas on deployment.
    ///      Validates registry address is non-zero and functional.
    /// @param _registry Address of the ParaSwap Augustus registry on this chain
    /// @param _weth Address of the WETH contract on this chain (for native ETH swaps)
    constructor(
        address _registry,
        address _weth
    ) payable SwapModuleBase(_weth) {
        require(_registry != address(0), "Invalid registry");
        require(
            !IParaSwapAugustusRegistry(_registry).isValidAugustus(address(0)),
            "Invalid registry"
        );
        registry = IParaSwapAugustusRegistry(_registry);
    }

    /// @inheritdoc ISwapModule
    function swap(
        SwapParams calldata params
    ) external override returns (SwapResult memory result) {
        (bytes memory callData, address augustus) = _decodeSwapData(params.swapData);
        if (!registry.isValidAugustus(augustus)) revert InvalidSwapTarget();

        uint256 inputBefore = SafeTransferLib.balanceOf(params.inputToken, address(this));
        uint256 outputBefore = SafeTransferLib.balanceOf(params.outputToken, address(this));

        _executeSwap(augustus, params.inputToken, params.inputAmount, callData);

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

        (bytes memory callData, address augustus) = _decodeSwapData(params.swapData);
        if (!registry.isValidAugustus(augustus)) revert InvalidSwapTarget();

        weth.deposit{value: msg.value}();

        uint256 inputBefore = weth.balanceOf(address(this));
        uint256 outputBefore = SafeTransferLib.balanceOf(params.outputToken, address(this));

        _executeSwap(augustus, address(weth), params.inputAmount, callData);

        uint256 outputAfter = SafeTransferLib.balanceOf(params.outputToken, address(this));
        uint256 inputAfter = weth.balanceOf(address(this));

        result.outputAmountReceived = outputAfter - outputBefore;
        result.inputAmountSpent = inputBefore - inputAfter;

        _validateResult(params, result);
        _transferOutput(params, result.outputAmountReceived);
        _refundExcessNative(params.refundTo, inputAfter);
    }

    /// @dev Executes swap through ParaSwap Augustus router
    ///      Approves tokens to the TokenTransferProxy (not the router directly)
    ///      following ParaSwap's security architecture
    /// @param augustus The validated ParaSwap Augustus router address
    /// @param inputToken The token being sold (WETH for native swaps)
    /// @param amount The amount to approve for the swap
    /// @param callData The encoded swap call data from the ParaSwap API
    ///        This should be obtained from ParaSwap's quote API and passed through unchanged
    function _executeSwap(
        address augustus,
        address inputToken,
        uint256 amount,
        bytes memory callData
    ) internal {
        address tokenTransferProxy = IParaSwapAugustus(augustus).getTokenTransferProxy();
        _approveIfNeeded(inputToken, tokenTransferProxy, amount);

        (bool success,) = augustus.call(callData);
        if (!success) _bubbleRevert();
    }
}
