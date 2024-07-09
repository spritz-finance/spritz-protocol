// SPDX-License-Identifier: UNLICENSED

import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

pragma solidity ^0.8.26;

/**
 * @title SpritzPayCore
 * @dev This contract acts as the core payment infrastructure for the Spritz Finance protocol
 */
contract SpritzPayCore is AccessControlEnumerable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /**
     * @notice Thrown when sweeping the contract fails
     */
    error FailedSweep();

    /**
     * @notice Thrown when calling the initializer after already being initialized
     */
    error Initialized();

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
    EnumerableSet.AddressSet internal _acceptedPaymentTokens;

    bool private _initialized;

    mapping(address => address) public tokenRecipients;

    constructor() payable {}

    function initialize(address admin) external {
        if (_initialized) revert Initialized();
        _initialized = true;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
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

        IERC20(paymentToken).safeTransfer(_paymentRecipient, paymentAmount);

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
    function isAcceptedToken(
        address tokenAddress
    ) external view returns (bool) {
        return _acceptedPaymentTokens.contains(tokenAddress);
    }

    /**
     * @dev Get the payment recipient for a token
     * @return The address of the payment recipient
     */
    function paymentRecipient(
        address tokenAddress
    ) external view returns (address) {
        return tokenRecipients[tokenAddress];
    }

    /**
     * @dev Adds an accepted payment token
     */
    function addPaymentToken(
        address newToken,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        _acceptedPaymentTokens.add(newToken);
        tokenRecipients[newToken] = recipient;
    }

    /**
     * @dev Adds an accepted payment token
     */
    function removePaymentToken(
        address newToken
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _acceptedPaymentTokens.remove(newToken);
        delete tokenRecipients[newToken];
    }

    /**
     * @dev Withdraw deposited tokens to the given address
     * @param token Token to withdraw
     * @param to Target address
     */
    function sweep(
        IERC20 token,
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }
}
