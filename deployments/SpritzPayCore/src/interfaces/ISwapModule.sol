// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ISwapModule
/// @notice Interface for swap modules that execute token conversions for SpritzRouter
/// @dev Implementations should handle DEX integrations (e.g., Uniswap, 1inch, Paraswap)
interface ISwapModule {
    /// @notice Swap execution type
    /// @dev ExactInput: spend exact input, receive variable output
    ///      ExactOutput: spend variable input, receive exact output
    enum SwapType {
        ExactInput,
        ExactOutput
    }

    /// @notice Parameters for executing a swap
    /// @param swapType Whether to use exact input or exact output
    /// @param inputToken The token being sold (address(0) for native ETH)
    /// @param outputToken The token being bought
    /// @param to Recipient of the output tokens
    /// @param refundTo Recipient of any excess input tokens (for ExactOutput swaps)
    /// @param inputAmount For ExactInput: exact amount to spend. For ExactOutput: max amount to spend
    /// @param outputAmount For ExactInput: min amount to receive. For ExactOutput: exact amount to receive
    /// @param deadline Unix timestamp after which the swap will revert
    /// @param swapData Arbitrary data for the swap (e.g., encoded DEX route)
    struct SwapParams {
        SwapType swapType;
        address inputToken;
        address outputToken;
        address to;
        address refundTo;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 deadline;
        bytes swapData;
    }

    /// @notice Result of a swap execution
    /// @param inputAmountSpent Actual amount of input tokens consumed
    /// @param outputAmountReceived Actual amount of output tokens received
    struct SwapResult {
        uint256 inputAmountSpent;
        uint256 outputAmountReceived;
    }

    /// @notice Execute a token-to-token swap
    /// @dev Input tokens must already be transferred to the swap module before calling
    /// @param params Swap parameters
    /// @return result The amounts spent and received
    function swap(SwapParams calldata params) external returns (SwapResult memory result);

    /// @notice Execute a swap with native ETH as input
    /// @dev msg.value should match params.inputAmount
    /// @param params Swap parameters (inputToken should be address(0))
    /// @return result The amounts spent and received
    function swapNative(SwapParams calldata params) external payable returns (SwapResult memory result);
}
