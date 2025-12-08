// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ISpritzPayCore
/// @notice Interface for the core payment processing contract
/// @dev Defines the minimal interface needed by SpritzRouter and external integrations
interface ISpritzPayCore {
    /// @notice Emitted when a payment is successfully processed
    /// @param to The recipient address that received the payment
    /// @param from The address that initiated the payment
    /// @param sourceToken The original token the payer used (may differ from paymentToken if swapped)
    /// @param sourceTokenAmount The amount of source token spent by the payer
    /// @param paymentToken The token that was actually transferred to the recipient
    /// @param paymentTokenAmount The amount of payment token received by the recipient
    /// @param paymentReference Unique identifier linking to an off-chain payment record
    event Payment(
        address to,
        address indexed from,
        address indexed sourceToken,
        uint256 sourceTokenAmount,
        address paymentToken,
        uint256 paymentTokenAmount,
        bytes32 indexed paymentReference
    );

    /// @notice Processes a payment by transferring tokens to the recipient and emitting an event
    /// @dev Tokens must be transferred to the contract before calling pay()
    /// @param caller The original payer address (used for event emission)
    /// @param paymentToken The token to transfer to the recipient (must be accepted)
    /// @param paymentAmount Amount of paymentToken to transfer
    /// @param sourceToken The token the payer originally used (for tracking, may equal paymentToken)
    /// @param sourceTokenSpent Amount of sourceToken the payer spent
    /// @param paymentReference Unique identifier for off-chain payment reconciliation
    function pay(
        address caller,
        address paymentToken,
        uint256 paymentAmount,
        address sourceToken,
        uint256 sourceTokenSpent,
        bytes32 paymentReference
    ) external;

    /// @notice Checks if a token is accepted for payments
    /// @param token The token address to check
    /// @return True if the token is accepted, false otherwise
    function isAcceptedToken(address token) external view returns (bool);

    /// @notice Returns the recipient address for a payment token
    /// @param token The payment token address
    /// @return The address that receives payments in this token
    function paymentRecipient(address token) external view returns (address);
}
