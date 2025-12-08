// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ISpritzRouter} from "./interfaces/ISpritzRouter.sol";
import {ISpritzPayCore} from "./interfaces/ISpritzPayCore.sol";
import {ISwapModule} from "./interfaces/ISwapModule.sol";

/// @title SpritzRouter
/// @notice Routes payments through SpritzPayCore with optional token swaps
/// @dev Supports multiple token approval patterns:
///      - Standard ERC20 approve + transferFrom
///      - EIP-2612 permit signatures
///      - Uniswap Permit2 (both AllowanceTransfer and SignatureTransfer)
///
///      Token transfers use Solady's SafeTransferLib which automatically
///      tries Permit2 AllowanceTransfer as a fallback when standard
///      transferFrom fails, enabling gasless approvals for supported tokens.
contract SpritzRouter is ISpritzRouter, Ownable, ReentrancyGuard {
    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

    /// @notice Thrown when an address has no code (not a contract)
    error NotAContract();

    /// @notice Thrown when a swap deadline has passed
    error DeadlineExpired();

    /// @notice Thrown when attempting a swap without a configured swap module
    error SwapModuleNotSet();

    /// @notice The SpritzPayCore contract that processes payments
    /// @dev Immutable as core address is consistent across all chains via CREATE3
    ISpritzPayCore public immutable core;

    /// @notice The swap module used for token conversions
    /// @dev Can be updated by owner to support different DEX aggregators
    ISwapModule public swapModule;

    /// @param _core Address of the SpritzPayCore contract
    constructor(address _core) payable {
        if (_core == address(0)) revert ZeroAddress();
        if (_core.code.length == 0) revert NotAContract();
        core = ISpritzPayCore(_core);
    }

    /// @dev Enables the initializer pattern for Solady Ownable
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /// @notice Initializes the contract owner
    /// @dev Can only be called once. Separate from constructor to support CREATE3 deployment
    /// @param _owner Address that will own the contract
    function initialize(address _owner) external {
        if (_owner == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
    }

    // ============ Admin ============

    /// @notice Updates the swap module used for token conversions
    /// @dev Set to address(0) to disable swaps
    /// @param newSwapModule Address of the new swap module
    function setSwapModule(address newSwapModule) external onlyOwner {
        if (newSwapModule != address(0) && newSwapModule.code.length == 0) {
            revert NotAContract();
        }
        swapModule = ISwapModule(newSwapModule);
    }

    // ============ Direct Payments ============

    /// @notice Pay with an accepted token using standard ERC20 approval
    /// @dev Caller must have approved this contract or Permit2 for the token amount
    /// @param token The payment token address (must be accepted by core)
    /// @param amount The payment amount
    /// @param paymentReference Unique identifier for the payment
    function payWithToken(address token, uint256 amount, bytes32 paymentReference) external {
        SafeTransferLib.safeTransferFrom2(token, msg.sender, address(core), amount);
        core.pay(msg.sender, token, amount, token, amount, paymentReference);
    }

    /// @notice Pay with an accepted token using a permit signature
    /// @dev Supports EIP-2612 permits, DAI-style permits, and Permit2 SignatureTransfer
    /// @param token The payment token address (must be accepted by core)
    /// @param amount The payment amount
    /// @param paymentReference Unique identifier for the payment
    /// @param permit The permit signature data
    function payWithToken(
        address token,
        uint256 amount,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external {
        SafeTransferLib.permit2(
            token,
            msg.sender,
            address(this),
            amount,
            permit.deadline,
            permit.v,
            permit.r,
            permit.s
        );

        SafeTransferLib.safeTransferFrom2(token, msg.sender, address(core), amount);

        core.pay(msg.sender, token, amount, token, amount, paymentReference);
    }

    // ============ Meta-Transaction Payments ============

    /// @notice Pay on behalf of another user using their permit signature
    /// @dev Enables gas-sponsored payments where a relayer submits the transaction
    /// @param owner The address that signed the permit and owns the tokens
    /// @param token The payment token address (must be accepted by core)
    /// @param amount The payment amount
    /// @param paymentReference Unique identifier for the payment
    /// @param permit The permit signature data signed by owner
    function payWithTokenOnBehalf(
        address owner,
        address token,
        uint256 amount,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external {
        SafeTransferLib.permit2(
            token,
            owner,
            address(this),
            amount,
            permit.deadline,
            permit.v,
            permit.r,
            permit.s
        );

        SafeTransferLib.safeTransferFrom2(token, owner, address(core), amount);

        core.pay(owner, token, amount, token, amount, paymentReference);
    }

    /// @notice Swap and pay on behalf of another user using their permit signature
    /// @dev Enables gas-sponsored swap payments where a relayer submits the transaction
    /// @param owner The address that signed the permit and owns the source tokens
    /// @param paymentToken The token to pay with after swap (must be accepted by core)
    /// @param swap Swap parameters including source token, amounts, and deadline
    /// @param paymentReference Unique identifier for the payment
    /// @param permit The permit signature data signed by owner for the source token
    function payWithSwapOnBehalf(
        address owner,
        address paymentToken,
        SwapPaymentParams calldata swap,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external nonReentrant {
        _validateSwap(swap.deadline);

        SafeTransferLib.permit2(
            swap.sourceToken,
            owner,
            address(this),
            swap.sourceAmount,
            permit.deadline,
            permit.v,
            permit.r,
            permit.s
        );

        SafeTransferLib.safeTransferFrom2(
            swap.sourceToken,
            owner,
            address(swapModule),
            swap.sourceAmount
        );

        _executeSwapAndPay(owner, paymentToken, swap, paymentReference);
    }

    // ============ Swap Payments ============

    /// @notice Swap tokens and pay in a single transaction
    /// @dev Caller must have approved this contract or Permit2 for the source token
    /// @param paymentToken The token to pay with after swap (must be accepted by core)
    /// @param swap Swap parameters including source token, amounts, and deadline
    /// @param paymentReference Unique identifier for the payment
    function payWithSwap(
        address paymentToken,
        SwapPaymentParams calldata swap,
        bytes32 paymentReference
    ) external nonReentrant {
        _validateSwap(swap.deadline);

        SafeTransferLib.safeTransferFrom2(
            swap.sourceToken,
            msg.sender,
            address(swapModule),
            swap.sourceAmount
        );

        _executeSwapAndPay(msg.sender, paymentToken, swap, paymentReference);
    }

    /// @notice Swap tokens and pay using a permit signature
    /// @dev Supports EIP-2612 permits, DAI-style permits, and Permit2 SignatureTransfer
    /// @param paymentToken The token to pay with after swap (must be accepted by core)
    /// @param swap Swap parameters including source token, amounts, and deadline
    /// @param paymentReference Unique identifier for the payment
    /// @param permit The permit signature data for the source token
    function payWithSwap(
        address paymentToken,
        SwapPaymentParams calldata swap,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external nonReentrant {
        _validateSwap(swap.deadline);

        SafeTransferLib.permit2(
            swap.sourceToken,
            msg.sender,
            address(this),
            swap.sourceAmount,
            permit.deadline,
            permit.v,
            permit.r,
            permit.s
        );

        SafeTransferLib.safeTransferFrom2(
            swap.sourceToken,
            msg.sender,
            address(swapModule),
            swap.sourceAmount
        );

        _executeSwapAndPay(msg.sender, paymentToken, swap, paymentReference);
    }

    /// @notice Swap native ETH and pay in a single transaction
    /// @dev msg.value is used as the swap input amount
    /// @param paymentToken The token to pay with after swap (must be accepted by core)
    /// @param swap Swap parameters (sourceToken should be address(0) for native ETH)
    /// @param paymentReference Unique identifier for the payment
    function payWithNativeSwap(
        address paymentToken,
        SwapPaymentParams calldata swap,
        bytes32 paymentReference
    ) external payable nonReentrant {
        _validateSwap(swap.deadline);

        ISwapModule.SwapParams memory swapParams = ISwapModule.SwapParams({
            swapType: swap.swapType,
            inputToken: swap.sourceToken,
            outputToken: paymentToken,
            to: address(core),
            refundTo: msg.sender,
            inputAmount: swap.sourceAmount,
            outputAmount: swap.paymentAmount,
            deadline: swap.deadline,
            swapData: swap.swapData
        });

        ISwapModule.SwapResult memory result = swapModule.swapNative{value: msg.value}(swapParams);

        _validateAndPay(msg.sender, paymentToken, swap, result, paymentReference);
    }

    // ============ Admin ============

    /// @notice Rescue tokens accidentally sent to this contract
    /// @dev Only callable by owner. Transfers entire balance of specified token
    /// @param token The token to sweep
    /// @param to The recipient address
    function sweep(address token, address to) external onlyOwner {
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        if (balance > 0) {
            SafeTransferLib.safeTransfer(token, to, balance);
        }
    }

    // ============ Internal ============

    /// @dev Validates swap module is set and deadline not passed
    function _validateSwap(uint256 deadline) internal view {
        if (address(swapModule) == address(0)) revert SwapModuleNotSet();
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    /// @dev Executes a swap via the swap module and processes the payment
    function _executeSwapAndPay(
        address payer,
        address paymentToken,
        SwapPaymentParams calldata swap,
        bytes32 paymentReference
    ) internal {
        ISwapModule.SwapParams memory swapParams = ISwapModule.SwapParams({
            swapType: swap.swapType,
            inputToken: swap.sourceToken,
            outputToken: paymentToken,
            to: address(core),
            refundTo: payer,
            inputAmount: swap.sourceAmount,
            outputAmount: swap.paymentAmount,
            deadline: swap.deadline,
            swapData: swap.swapData
        });

        ISwapModule.SwapResult memory result = swapModule.swap(swapParams);

        _validateAndPay(payer, paymentToken, swap, result, paymentReference);
    }

    /// @dev Validates swap result and records payment via SpritzPayCore
    function _validateAndPay(
        address payer,
        address paymentToken,
        SwapPaymentParams calldata swap,
        ISwapModule.SwapResult memory result,
        bytes32 paymentReference
    ) internal {
        core.pay(
            payer,
            paymentToken,
            result.outputAmountReceived,
            swap.sourceToken,
            result.inputAmountSpent,
            paymentReference
        );
    }
}
