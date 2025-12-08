// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";

/// @title SpritzPayCore
/// @notice Core payment processing contract for Spritz Finance protocol
/// @dev Handles token allowlisting, recipient management, and payment event emission.
///      Designed to be called by SpritzRouter or directly for simple payments.
///      Uses Solady for gas-efficient ownership and token transfers.
contract SpritzPayCore is Ownable {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @notice Thrown when attempting to pay with a token that is not accepted
    /// @param token The token address that was rejected
    error TokenNotAccepted(address token);

    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

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

    /// @dev Set of all accepted payment token addresses
    EnumerableSetLib.AddressSet internal _acceptedPaymentTokens;

    /// @notice Maps payment token addresses to their designated recipient addresses
    mapping(address => address) public tokenRecipients;

    /// @dev Constructor is payable to save gas on deployment
    constructor() payable {}

    /// @dev Enables the initializer pattern for Solady Ownable
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /// @notice Initializes the contract with an admin owner
    /// @dev Can only be called once. Separate from constructor to support CREATE3 deployment.
    /// @param admin Address that will own the contract and manage payment tokens
    function initialize(address admin) external {
        _initializeOwner(admin);
    }

    /// @notice Processes a payment by transferring tokens to the recipient and emitting an event
    /// @dev Tokens must be transferred to this contract before calling pay().
    ///      Typically called by SpritzRouter after handling approvals/swaps.
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
    ) external {
        address _paymentRecipient = tokenRecipients[paymentToken];
        if (_paymentRecipient == address(0))
            revert TokenNotAccepted(paymentToken);

        emit Payment(
            _paymentRecipient,
            caller,
            sourceToken,
            sourceTokenSpent,
            paymentToken,
            paymentAmount,
            paymentReference
        );

        SafeTransferLib.safeTransfer(
            paymentToken,
            _paymentRecipient,
            paymentAmount
        );
    }

    // ============ View Functions ============

    /// @notice Returns all accepted payment token addresses
    /// @return Array of token addresses that can be used for payments
    function acceptedPaymentTokens() external view returns (address[] memory) {
        return _acceptedPaymentTokens.values();
    }

    /// @notice Checks if a token is accepted for payments
    /// @param tokenAddress The token address to check
    /// @return True if the token is accepted, false otherwise
    function isAcceptedToken(
        address tokenAddress
    ) external view returns (bool) {
        return _acceptedPaymentTokens.contains(tokenAddress);
    }

    /// @notice Returns the recipient address for a payment token
    /// @param tokenAddress The payment token address
    /// @return The address that receives payments in this token (zero if not accepted)
    function paymentRecipient(
        address tokenAddress
    ) external view returns (address) {
        return tokenRecipients[tokenAddress];
    }

    // ============ Admin Functions ============

    /// @notice Adds or updates an accepted payment token with its recipient
    /// @dev Only callable by owner. Updates recipient if token already exists.
    /// @param token The token address to accept
    /// @param recipient The address that will receive payments in this token
    function addPaymentToken(
        address token,
        address recipient
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        _acceptedPaymentTokens.add(token);
        tokenRecipients[token] = recipient;
    }

    /// @notice Removes a payment token from the accepted list
    /// @dev Only callable by owner. Payments with this token will revert after removal.
    /// @param token The token address to remove
    function removePaymentToken(address token) external onlyOwner {
        _acceptedPaymentTokens.remove(token);
        delete tokenRecipients[token];
    }

    /// @notice Rescues tokens accidentally sent to this contract
    /// @dev Only callable by owner. Transfers entire balance of specified token.
    /// @param token The token to sweep
    /// @param to The recipient address
    function sweep(address token, address to) external onlyOwner {
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        if (balance > 0) {
            SafeTransferLib.safeTransfer(token, to, balance);
        }
    }
}
