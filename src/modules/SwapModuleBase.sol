// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ISwapModule} from "../interfaces/ISwapModule.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";

/// @title SwapModuleBase
/// @notice Abstract base contract for swap module implementations
/// @dev Provides shared validation, transfer, and refund logic for all swap modules
abstract contract SwapModuleBase is ISwapModule {
    /// @notice Thrown when the swap target address is invalid
    error InvalidSwapTarget();

    /// @notice Thrown when input amount spent exceeds maximum allowed (ExactOutput)
    error InsufficientInput();

    /// @notice Thrown when output amount received is below minimum required
    error InsufficientOutput();

    /// @notice Thrown when the swap call to the DEX fails
    error SwapFailed();

    /// @notice Thrown when refunding excess tokens/ETH fails
    error RefundFailed();

    /// @notice Thrown when swapNative is called with non-zero inputToken
    error InvalidNativeSwap();

    /// @notice The WETH contract for native ETH swaps
    IWETH9 public immutable weth;

    /// @param _weth Address of the WETH contract
    constructor(address _weth) {
        require(_weth != address(0), "Invalid WETH");
        weth = IWETH9(_weth);
    }

    /// @dev Validates swap result based on swap type
    /// For ExactInput: validates output >= minimum
    /// For ExactOutput: validates output >= exact amount AND input <= maximum
    function _validateResult(
        SwapParams calldata params,
        SwapResult memory result
    ) internal pure {
        if (result.outputAmountReceived < params.outputAmount) {
            revert InsufficientOutput();
        }
        if (params.swapType == SwapType.ExactOutput) {
            if (result.inputAmountSpent > params.inputAmount) {
                revert InsufficientInput();
            }
        }
    }

    /// @dev Transfers output tokens based on swap type
    /// For ExactInput: send all output to recipient
    /// For ExactOutput: send exact amount to recipient, refund excess to user
    function _transferOutput(
        SwapParams calldata params,
        uint256 outputReceived
    ) internal {
        if (params.swapType == SwapType.ExactInput) {
            SafeTransferLib.safeTransfer(
                params.outputToken,
                params.to,
                outputReceived
            );
        } else {
            SafeTransferLib.safeTransfer(
                params.outputToken,
                params.to,
                params.outputAmount
            );
            uint256 excessOutput = outputReceived - params.outputAmount;
            if (excessOutput > 0) {
                SafeTransferLib.safeTransfer(
                    params.outputToken,
                    params.refundTo,
                    excessOutput
                );
            }
        }
    }

    /// @dev Refunds excess ERC20 input tokens to the user
    function _refundExcessInput(
        address inputToken,
        address refundTo,
        uint256 amount
    ) internal {
        if (amount > 0) {
            SafeTransferLib.safeTransfer(inputToken, refundTo, amount);
        }
    }

    /// @dev Refunds excess native ETH to the user (withdraws from WETH first)
    function _refundExcessNative(address refundTo, uint256 amount) internal {
        if (amount > 0) {
            weth.withdraw(amount);
            (bool success,) = refundTo.call{value: amount}("");
            if (!success) revert RefundFailed();
        }
    }

    /// @dev Decodes swap data containing the calldata and target address
    /// @param swapData Encoded as (bytes calldata, address target)
    function _decodeSwapData(
        bytes calldata swapData
    ) internal pure returns (bytes memory callData, address target) {
        (callData, target) = abi.decode(swapData, (bytes, address));
    }

    /// @dev Approves token for spender if current allowance is insufficient
    function _approveIfNeeded(
        address token,
        address spender,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature(
                "allowance(address,address)",
                address(this),
                spender
            )
        );

        uint256 currentAllowance;
        if (success && data.length >= 32) {
            currentAllowance = abi.decode(data, (uint256));
        }

        if (currentAllowance < amount) {
            SafeTransferLib.safeApproveWithRetry(
                token,
                spender,
                type(uint256).max
            );
        }
    }

    /// @dev Bubbles up revert data from a failed call
    function _bubbleRevert() internal pure {
        assembly {
            returndatacopy(0, 0, returndatasize())
            revert(0, returndatasize())
        }
    }

    /// @dev Required to receive ETH refunds from WETH
    receive() external payable {}
}
