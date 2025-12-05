// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISwapModule} from "./ISwapModule.sol";
import {ISpritzPayCore} from "./ISpritzPayCore.sol";

/// @title ISpritzRouter
/// @notice Interface for routing payments through SpritzPayCore with optional token swaps
interface ISpritzRouter {
    /// @notice Parameters for swap-based payments
    /// @param swapType Whether to use ExactInput or ExactOutput swap
    /// @param sourceToken The token to swap from (address(0) for native ETH)
    /// @param sourceAmount The amount of source token (max input for ExactOutput, exact input for ExactInput)
    /// @param paymentAmount The payment amount (exact output for ExactOutput, min output for ExactInput)
    /// @param deadline Unix timestamp after which the swap will revert
    /// @param swapData Arbitrary data passed to the swap module (e.g., DEX route)
    struct SwapPaymentParams {
        ISwapModule.SwapType swapType;
        address sourceToken;
        uint256 sourceAmount;
        uint256 paymentAmount;
        uint256 deadline;
        bytes swapData;
    }

    /// @notice EIP-2612 permit signature data
    /// @param deadline Unix timestamp after which the permit is invalid
    /// @param v ECDSA signature v component
    /// @param r ECDSA signature r component
    /// @param s ECDSA signature s component
    struct PermitData {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // ============ State ============

    /// @notice Returns the SpritzPayCore contract address
    function core() external view returns (ISpritzPayCore);

    /// @notice Returns the current swap module address
    function swapModule() external view returns (ISwapModule);

    // ============ Initialization ============

    /// @notice Initializes the contract owner
    /// @param _owner Address that will own the contract
    function initialize(address _owner) external;

    // ============ Admin ============

    /// @notice Updates the swap module
    /// @param newSwapModule Address of the new swap module
    function setSwapModule(address newSwapModule) external;

    // ============ Direct Payments ============

    /// @notice Pay with an accepted token using standard ERC20 approval
    /// @param token The payment token address
    /// @param amount The payment amount
    /// @param paymentReference Unique identifier for the payment
    function payWithToken(address token, uint256 amount, bytes32 paymentReference) external;

    /// @notice Pay with an accepted token using a permit signature
    /// @param token The payment token address
    /// @param amount The payment amount
    /// @param paymentReference Unique identifier for the payment
    /// @param permit The permit signature data
    function payWithToken(
        address token,
        uint256 amount,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external;

    // ============ Meta-Transaction Payments ============

    /// @notice Pay on behalf of another user using their permit signature
    /// @param owner The address that signed the permit and owns the tokens
    /// @param token The payment token address
    /// @param amount The payment amount
    /// @param paymentReference Unique identifier for the payment
    /// @param permit The permit signature data signed by owner
    function payWithTokenOnBehalf(
        address owner,
        address token,
        uint256 amount,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external;

    /// @notice Swap and pay on behalf of another user using their permit signature
    /// @param owner The address that signed the permit and owns the source tokens
    /// @param paymentToken The token to pay with after swap
    /// @param swap Swap parameters
    /// @param paymentReference Unique identifier for the payment
    /// @param permit The permit signature data signed by owner for the source token
    function payWithSwapOnBehalf(
        address owner,
        address paymentToken,
        SwapPaymentParams calldata swap,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external;

    // ============ Swap Payments ============

    /// @notice Swap tokens and pay in a single transaction
    /// @param paymentToken The token to pay with after swap
    /// @param swap Swap parameters
    /// @param paymentReference Unique identifier for the payment
    function payWithSwap(
        address paymentToken,
        SwapPaymentParams calldata swap,
        bytes32 paymentReference
    ) external;

    /// @notice Swap tokens and pay using a permit signature
    /// @param paymentToken The token to pay with after swap
    /// @param swap Swap parameters
    /// @param paymentReference Unique identifier for the payment
    /// @param permit The permit signature data for the source token
    function payWithSwap(
        address paymentToken,
        SwapPaymentParams calldata swap,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external;

    /// @notice Swap native ETH and pay in a single transaction
    /// @param paymentToken The token to pay with after swap
    /// @param swap Swap parameters
    /// @param paymentReference Unique identifier for the payment
    function payWithNativeSwap(
        address paymentToken,
        SwapPaymentParams calldata swap,
        bytes32 paymentReference
    ) external payable;

    // ============ Admin ============

    /// @notice Rescue tokens accidentally sent to this contract
    /// @param token The token to sweep
    /// @param to The recipient address
    function sweep(address token, address to) external;
}
