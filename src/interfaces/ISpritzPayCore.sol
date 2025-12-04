// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISpritzPayCore {
    event Payment(
        address to,
        address indexed from,
        address indexed sourceToken,
        uint256 sourceTokenAmount,
        address paymentToken,
        uint256 paymentTokenAmount,
        bytes32 indexed paymentReference
    );

    /// @notice Process payment - transfer tokens to recipient and emit event
    /// @param caller The original payment sender (for event)
    /// @param paymentToken The token being paid
    /// @param paymentAmount Amount of payment token
    /// @param sourceToken Original token user paid with (may differ if swapped)
    /// @param sourceTokenSpent Amount of source token spent
    /// @param paymentReference Unique payment identifier
    function pay(
        address caller,
        address paymentToken,
        uint256 paymentAmount,
        address sourceToken,
        uint256 sourceTokenSpent,
        bytes32 paymentReference
    ) external;

    /// @notice Check if token is accepted for payments
    function isAcceptedToken(address token) external view returns (bool);

    /// @notice Get recipient address for a payment token
    function paymentRecipient(address token) external view returns (address);
}
