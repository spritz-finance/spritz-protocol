// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";

/**
 * @title SpritzPayCore
 * @dev Core payment infrastructure for Spritz Finance protocol.
 * Uses Solady for gas-efficient ownership and token transfers.
 */
contract SpritzPayCore is Ownable {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /**
     * @notice Thrown when paying with unrecognized token
     */
    error TokenNotAccepted(address token);

    /**
     * @notice Thrown when setting the zero address in a variable
     */
    error ZeroAddress();

    /**
     * @dev Emitted when a payment has been successfully sent
     */
    event Payment(
        address to,
        address indexed from,
        address indexed sourceToken,
        uint256 sourceTokenAmount,
        address paymentToken,
        uint256 paymentTokenAmount,
        bytes32 indexed paymentReference
    );

    /// @notice List of all accepted payment tokens
    EnumerableSetLib.AddressSet internal _acceptedPaymentTokens;

    mapping(address => address) public tokenRecipients;

    constructor() payable {}

    /// @dev Prevents double-initialization (Solady pattern)
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    function initialize(address admin) external {
        _initializeOwner(admin);
    }

    /**
     * @notice Core payment infrastructure - transfers tokens to payment recipient
     * and emits event to be processed offchain.
     * @dev requires that tokens be send to SpritzPayCore before calling the
     * pay method.
     * @param caller Address of the payment sender
     * @param paymentToken Address of the target payment token
     * @param paymentAmount Payment amount, denominated in target payment token
     * @param sourceToken Address of the original source token used for payment, as a reference
     * @param sourceTokenSpent The amount of the original source token
     * @param paymentReference Arbitrary reference ID of the related payment
     */
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

        SafeTransferLib.safeTransfer(paymentToken, _paymentRecipient, paymentAmount);

        emit Payment(
            _paymentRecipient,
            caller,
            sourceToken,
            sourceTokenSpent,
            paymentToken,
            paymentAmount,
            paymentReference
        );
    }

    /**
     * @dev Get all accepted payment tokens
     * @return An array of the unique token addresses
     */
    function acceptedPaymentTokens() external view returns (address[] memory) {
        return _acceptedPaymentTokens.values();
    }

    /**
     * @dev Get all accepted payment tokens
     * @return Whether this payment token is accepted
     */
    function isAcceptedToken(address tokenAddress) external view returns (bool) {
        return _acceptedPaymentTokens.contains(tokenAddress);
    }

    /**
     * @dev Get the payment recipient for a token
     * @return The address of the payment recipient
     */
    function paymentRecipient(address tokenAddress) external view returns (address) {
        return tokenRecipients[tokenAddress];
    }

    /**
     * @dev Adds an accepted payment token
     */
    function addPaymentToken(address token, address recipient) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        _acceptedPaymentTokens.add(token);
        tokenRecipients[token] = recipient;
    }

    /**
     * @dev Removes an accepted payment token
     */
    function removePaymentToken(address token) external onlyOwner {
        _acceptedPaymentTokens.remove(token);
        delete tokenRecipients[token];
    }

    /**
     * @dev Withdraw deposited tokens to the given address
     * @param token Token to withdraw
     * @param to Target address
     */
    function sweep(address token, address to) external onlyOwner {
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        if (balance > 0) {
            SafeTransferLib.safeTransfer(token, to, balance);
        }
    }
}
