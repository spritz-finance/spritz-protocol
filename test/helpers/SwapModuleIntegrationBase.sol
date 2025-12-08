// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpritzRouter} from "../../src/SpritzRouter.sol";
import {SpritzPayCore} from "../../src/SpritzPayCore.sol";
import {ISpritzRouter} from "../../src/interfaces/ISpritzRouter.sol";
import {ISwapModule} from "../../src/interfaces/ISwapModule.sol";
import {ERC20Mock} from "../../src/test/ERC20Mock.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockDEXExchange} from "../mocks/MockDEX.sol";

/// @title SwapModuleIntegrationBase
/// @notice Abstract base contract for swap module integration tests
/// @dev Provides common test cases that apply to all swap modules
abstract contract SwapModuleIntegrationBase is Test {
    SpritzRouter public router;
    SpritzPayCore public core;
    MockWETH public weth;

    ERC20Mock public sourceToken;
    ERC20Mock public paymentToken;

    address public admin;
    address public user;
    address public recipient;

    event Payment(
        address to,
        address indexed from,
        address indexed sourceToken,
        uint256 sourceTokenAmount,
        address paymentToken,
        uint256 paymentTokenAmount,
        bytes32 indexed paymentReference
    );

    function _baseSetUp() internal {
        admin = makeAddr("admin");
        user = makeAddr("user");
        recipient = makeAddr("recipient");

        weth = new MockWETH();

        core = new SpritzPayCore();
        core.initialize(admin);

        router = new SpritzRouter(address(core));
        router.initialize(admin);

        sourceToken = new ERC20Mock();
        paymentToken = new ERC20Mock();

        vm.prank(admin);
        core.addPaymentToken(address(paymentToken), recipient);

        vm.label(address(router), "Router");
        vm.label(address(core), "Core");
        vm.label(address(weth), "WETH");
        vm.label(address(sourceToken), "SourceToken");
        vm.label(address(paymentToken), "PaymentToken");
    }

    /// @dev Subclasses must implement to return the swap module address
    function _swapModule() internal view virtual returns (address);

    /// @dev Subclasses must implement to return the mock exchange
    function _exchange() internal view virtual returns (MockDEXExchange);

    /// @dev Subclasses must implement to encode swap data for their module
    function _encodeSwapData(bytes memory callData) internal view virtual returns (bytes memory);

    /// @dev Subclasses must implement to return the expected revert selector for insufficient output
    function _insufficientOutputSelector() internal pure virtual returns (bytes4);

    /// @dev Subclasses must implement to return the expected revert selector for insufficient input
    function _insufficientInputSelector() internal pure virtual returns (bytes4);

    // ============ ExactInput Integration Tests ============

    function test_ExactInput_FullFlow() public {
        uint256 sourceAmount = 1000e18;
        uint256 minPaymentAmount = 900e18;
        bytes32 paymentRef = keccak256("exact-input-test");

        _exchange().setSwapRate(1e18);

        sourceToken.mint(user, sourceAmount);

        vm.prank(user);
        sourceToken.approve(address(router), sourceAmount);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(
                MockDEXExchange.swap.selector, address(sourceToken), address(paymentToken), sourceAmount
            )
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(sourceToken),
            sourceAmount: sourceAmount,
            paymentAmount: minPaymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.expectEmit(true, true, true, true);
        emit Payment(
            recipient, user, address(sourceToken), sourceAmount, address(paymentToken), sourceAmount, paymentRef
        );

        vm.prank(user);
        router.payWithSwap(address(paymentToken), swapParams, paymentRef);

        assertEq(sourceToken.balanceOf(user), 0, "User should have spent all source tokens");
        assertEq(paymentToken.balanceOf(recipient), sourceAmount, "Recipient should receive payment");
        assertEq(sourceToken.balanceOf(_swapModule()), 0, "Module should not hold tokens");
    }

    function test_ExactInput_BetterThanMinOutput() public {
        uint256 sourceAmount = 1000e18;
        uint256 minPaymentAmount = 800e18;

        _exchange().setSwapRate(1.5e18);
        uint256 expectedOutput = 1500e18;

        sourceToken.mint(user, sourceAmount);
        vm.prank(user);
        sourceToken.approve(address(router), sourceAmount);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(
                MockDEXExchange.swap.selector, address(sourceToken), address(paymentToken), sourceAmount
            )
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(sourceToken),
            sourceAmount: sourceAmount,
            paymentAmount: minPaymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.prank(user);
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));

        assertEq(paymentToken.balanceOf(recipient), expectedOutput, "Recipient gets full swap output");
    }

    function test_ExactInput_RevertWhen_SlippageExceeded() public {
        uint256 sourceAmount = 1000e18;
        uint256 minPaymentAmount = 900e18;

        _exchange().setSwapRate(0.5e18);

        sourceToken.mint(user, sourceAmount);
        vm.prank(user);
        sourceToken.approve(address(router), sourceAmount);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(
                MockDEXExchange.swap.selector, address(sourceToken), address(paymentToken), sourceAmount
            )
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(sourceToken),
            sourceAmount: sourceAmount,
            paymentAmount: minPaymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.prank(user);
        vm.expectRevert(_insufficientOutputSelector());
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));
    }

    // ============ ExactOutput Integration Tests ============

    function test_ExactOutput_FullFlow() public {
        uint256 maxSourceAmount = 1000e18;
        uint256 exactPaymentAmount = 500e18;
        bytes32 paymentRef = keccak256("exact-output-test");

        _exchange().setSwapRate(1e18);

        sourceToken.mint(user, maxSourceAmount);
        vm.prank(user);
        sourceToken.approve(address(router), maxSourceAmount);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(
                MockDEXExchange.swapExactOutput.selector,
                address(sourceToken),
                address(paymentToken),
                exactPaymentAmount
            )
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: maxSourceAmount,
            paymentAmount: exactPaymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.prank(user);
        router.payWithSwap(address(paymentToken), swapParams, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), exactPaymentAmount, "Recipient receives exact payment");
        assertEq(sourceToken.balanceOf(user), maxSourceAmount - exactPaymentAmount, "User gets refund");
    }

    function test_ExactOutput_RefundsExcessInput() public {
        uint256 maxSourceAmount = 1000e18;
        uint256 exactPaymentAmount = 200e18;

        _exchange().setSwapRate(1e18);

        sourceToken.mint(user, maxSourceAmount);
        vm.prank(user);
        sourceToken.approve(address(router), maxSourceAmount);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(
                MockDEXExchange.swapExactOutput.selector,
                address(sourceToken),
                address(paymentToken),
                exactPaymentAmount
            )
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: maxSourceAmount,
            paymentAmount: exactPaymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.prank(user);
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));

        assertEq(sourceToken.balanceOf(user), 800e18, "User refunded 800 tokens");
        assertEq(sourceToken.balanceOf(_swapModule()), 0, "Module holds no tokens");
        assertEq(sourceToken.balanceOf(address(router)), 0, "Router holds no tokens");
    }

    function test_ExactOutput_RevertWhen_ExceedsMaxInput() public {
        uint256 maxSourceAmount = 100e18;
        uint256 exactPaymentAmount = 500e18;

        _exchange().setSwapRate(1e18);

        sourceToken.mint(user, maxSourceAmount);
        sourceToken.mint(_swapModule(), 500e18);

        vm.prank(user);
        sourceToken.approve(address(router), maxSourceAmount);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(
                MockDEXExchange.swapExactOutput.selector,
                address(sourceToken),
                address(paymentToken),
                exactPaymentAmount
            )
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: maxSourceAmount,
            paymentAmount: exactPaymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.prank(user);
        vm.expectRevert(_insufficientInputSelector());
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));
    }

    // ============ Native ETH Integration Tests ============

    function test_NativeSwap_ExactInput() public {
        uint256 ethAmount = 1 ether;
        uint256 minPaymentAmount = 1000e18;
        bytes32 paymentRef = keccak256("native-swap");

        _exchange().setSwapRate(1000e18);

        vm.deal(user, ethAmount);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(MockDEXExchange.swap.selector, address(weth), address(paymentToken), ethAmount)
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(0),
            sourceAmount: ethAmount,
            paymentAmount: minPaymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.prank(user);
        router.payWithNativeSwap{value: ethAmount}(address(paymentToken), swapParams, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), 1000e18, "Recipient receives payment");
        assertEq(user.balance, 0, "User spent all ETH");
    }

    function test_NativeSwap_ExactOutput_RefundsETH() public {
        uint256 maxEthAmount = 1 ether;
        uint256 exactPaymentAmount = 500e18;

        _exchange().setSwapRate(1000e18);

        vm.deal(user, maxEthAmount);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(
                MockDEXExchange.swapExactOutput.selector, address(weth), address(paymentToken), exactPaymentAmount
            )
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(0),
            sourceAmount: maxEthAmount,
            paymentAmount: exactPaymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.prank(user);
        router.payWithNativeSwap{value: maxEthAmount}(address(paymentToken), swapParams, bytes32(0));

        assertEq(paymentToken.balanceOf(recipient), exactPaymentAmount, "Recipient receives exact payment");
        assertEq(user.balance, 0.5 ether, "User refunded excess ETH");
    }

    // ============ Invariants ============

    function test_SwapModule_NeverHoldsFunds() public {
        uint256 sourceAmount = 1000e18;

        _exchange().setSwapRate(1e18);

        sourceToken.mint(user, sourceAmount);
        vm.prank(user);
        sourceToken.approve(address(router), sourceAmount);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(
                MockDEXExchange.swap.selector, address(sourceToken), address(paymentToken), sourceAmount
            )
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(sourceToken),
            sourceAmount: sourceAmount,
            paymentAmount: 0,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.prank(user);
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));

        assertEq(sourceToken.balanceOf(_swapModule()), 0, "Module holds no source tokens");
        assertEq(paymentToken.balanceOf(_swapModule()), 0, "Module holds no payment tokens");
        assertEq(sourceToken.balanceOf(address(router)), 0, "Router holds no source tokens");
        assertEq(paymentToken.balanceOf(address(router)), 0, "Router holds no payment tokens");
    }

    function test_RevertWhen_DeadlineExpired() public {
        sourceToken.mint(user, 1000e18);
        vm.prank(user);
        sourceToken.approve(address(router), 1000e18);

        bytes memory swapData = _encodeSwapData(
            abi.encodeWithSelector(
                MockDEXExchange.swap.selector, address(sourceToken), address(paymentToken), 1000e18
            )
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(sourceToken),
            sourceAmount: 1000e18,
            paymentAmount: 0,
            deadline: block.timestamp - 1,
            swapData: swapData
        });

        vm.prank(user);
        vm.expectRevert(SpritzRouter.DeadlineExpired.selector);
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));
    }

    function test_RevertWhen_SwapModuleNotSet() public {
        vm.prank(admin);
        router.setSwapModule(address(0));

        sourceToken.mint(user, 1000e18);
        vm.prank(user);
        sourceToken.approve(address(router), 1000e18);

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(sourceToken),
            sourceAmount: 1000e18,
            paymentAmount: 0,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.prank(user);
        vm.expectRevert(SpritzRouter.SwapModuleNotSet.selector);
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));
    }

    receive() external payable {}
}
