// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {OpenOceanModule} from "../src/modules/OpenOceanModule.sol";
import {SwapModuleBase} from "../src/modules/SwapModuleBase.sol";
import {ISwapModule} from "../src/interfaces/ISwapModule.sol";
import {ERC20Mock} from "../src/test/ERC20Mock.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockDEXExchange} from "./mocks/MockDEX.sol";

/// @title OpenOceanModule Unit Tests
/// @notice Tests the OpenOcean swap module in isolation
contract OpenOceanModuleTest is Test {
    OpenOceanModule public module;
    MockDEXExchange public exchange;
    MockWETH public weth;

    ERC20Mock public inputToken;
    ERC20Mock public outputToken;

    address public recipient;
    address public refundTo;

    function setUp() public {
        exchange = new MockDEXExchange();
        weth = new MockWETH();

        module = new OpenOceanModule(address(exchange), address(weth));

        inputToken = new ERC20Mock();
        outputToken = new ERC20Mock();

        recipient = makeAddr("recipient");
        refundTo = makeAddr("refundTo");

        vm.label(address(module), "OpenOceanModule");
        vm.label(address(exchange), "MockExchange");
        vm.label(address(weth), "WETH");
    }

    // ============ ExactInput Tests ============

    function test_ExactInput_BasicSwap() public {
        uint256 inputAmount = 1000e18;

        inputToken.mint(address(module), inputAmount);

        ISwapModule.SwapParams memory params = _createSwapParams(
            ISwapModule.SwapType.ExactInput,
            inputAmount,
            inputAmount // minOutput
        );

        ISwapModule.SwapResult memory result = module.swap(params);

        assertEq(result.inputAmountSpent, inputAmount);
        assertEq(result.outputAmountReceived, inputAmount);
        assertEq(outputToken.balanceOf(recipient), inputAmount);
    }

    function test_ExactInput_WithSlippage() public {
        uint256 inputAmount = 1000e18;
        uint256 minOutput = 800e18;

        exchange.setSwapRate(0.9e18);

        inputToken.mint(address(module), inputAmount);

        ISwapModule.SwapParams memory params = _createSwapParams(ISwapModule.SwapType.ExactInput, inputAmount, minOutput);

        ISwapModule.SwapResult memory result = module.swap(params);

        assertEq(result.outputAmountReceived, 900e18);
        assertGe(result.outputAmountReceived, minOutput);
    }

    function test_ExactInput_RevertWhen_InsufficientOutput() public {
        uint256 inputAmount = 1000e18;
        uint256 minOutput = 1000e18;

        exchange.setSwapRate(0.5e18);

        inputToken.mint(address(module), inputAmount);

        ISwapModule.SwapParams memory params = _createSwapParams(ISwapModule.SwapType.ExactInput, inputAmount, minOutput);

        vm.expectRevert(SwapModuleBase.InsufficientOutput.selector);
        module.swap(params);
    }

    // ============ ExactOutput Tests ============

    function test_ExactOutput_BasicSwap() public {
        uint256 maxInput = 1000e18;
        uint256 exactOutput = 500e18;

        inputToken.mint(address(module), maxInput);

        ISwapModule.SwapParams memory params = _createExactOutputParams(maxInput, exactOutput);

        ISwapModule.SwapResult memory result = module.swap(params);

        assertEq(result.outputAmountReceived, exactOutput);
        assertEq(result.inputAmountSpent, exactOutput);
        assertEq(outputToken.balanceOf(recipient), exactOutput);
        assertEq(inputToken.balanceOf(refundTo), maxInput - exactOutput);
    }

    function test_ExactOutput_RefundExcessInput() public {
        uint256 maxInput = 1000e18;
        uint256 exactOutput = 200e18;

        inputToken.mint(address(module), maxInput);

        ISwapModule.SwapParams memory params = _createExactOutputParams(maxInput, exactOutput);

        ISwapModule.SwapResult memory result = module.swap(params);

        assertEq(result.inputAmountSpent, exactOutput);
        assertEq(inputToken.balanceOf(refundTo), 800e18);
    }

    function test_ExactOutput_RefundExcessOutput() public {
        uint256 maxInput = 1000e18;
        uint256 exactOutput = 500e18;
        uint256 actualOutput = 600e18;

        exchange.setOutputOverride(actualOutput);

        inputToken.mint(address(module), maxInput);

        ISwapModule.SwapParams memory params = _createExactOutputParams(maxInput, exactOutput);

        ISwapModule.SwapResult memory result = module.swap(params);

        assertEq(result.outputAmountReceived, actualOutput);
        assertEq(outputToken.balanceOf(recipient), exactOutput, "Recipient gets exact requested amount");
        assertEq(outputToken.balanceOf(refundTo), actualOutput - exactOutput, "User gets excess output refunded");
    }

    function test_ExactOutput_RevertWhen_ExceedsMaxInput() public {
        uint256 maxInput = 100e18;
        uint256 exactOutput = 500e18;

        inputToken.mint(address(module), 1000e18);

        ISwapModule.SwapParams memory params = _createExactOutputParams(maxInput, exactOutput);

        vm.expectRevert(SwapModuleBase.InsufficientInput.selector);
        module.swap(params);
    }

    // ============ Native ETH Tests ============

    function test_SwapNative_ExactInput() public {
        uint256 inputAmount = 1 ether;
        uint256 minOutput = 1000e18;

        exchange.setSwapRate(1000e18);

        vm.deal(address(this), inputAmount);

        ISwapModule.SwapParams memory params = ISwapModule.SwapParams({
            swapType: ISwapModule.SwapType.ExactInput,
            inputToken: address(0),
            outputToken: address(outputToken),
            to: recipient,
            refundTo: refundTo,
            inputAmount: inputAmount,
            outputAmount: minOutput,
            deadline: block.timestamp + 1 hours,
            swapData: _encodeSwapData(
                abi.encodeWithSelector(MockDEXExchange.swap.selector, address(weth), address(outputToken), inputAmount)
            )
        });

        ISwapModule.SwapResult memory result = module.swapNative{value: inputAmount}(params);

        assertEq(result.outputAmountReceived, 1000e18);
        assertEq(outputToken.balanceOf(recipient), 1000e18);
    }

    function test_SwapNative_RefundExcessETH() public {
        uint256 inputAmount = 1 ether;
        uint256 exactOutput = 500e18;

        exchange.setSwapRate(1000e18);

        vm.deal(address(this), inputAmount);

        ISwapModule.SwapParams memory params = ISwapModule.SwapParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            inputToken: address(0),
            outputToken: address(outputToken),
            to: recipient,
            refundTo: refundTo,
            inputAmount: inputAmount,
            outputAmount: exactOutput,
            deadline: block.timestamp + 1 hours,
            swapData: _encodeSwapData(
                abi.encodeWithSelector(
                    MockDEXExchange.swapExactOutput.selector, address(weth), address(outputToken), exactOutput
                )
            )
        });

        uint256 refundBalanceBefore = refundTo.balance;

        module.swapNative{value: inputAmount}(params);

        assertGt(refundTo.balance, refundBalanceBefore);
    }

    function test_SwapNative_RevertWhen_InputTokenNotZero() public {
        vm.deal(address(this), 1 ether);

        ISwapModule.SwapParams memory params = ISwapModule.SwapParams({
            swapType: ISwapModule.SwapType.ExactInput,
            inputToken: address(inputToken), // Should be address(0)
            outputToken: address(outputToken),
            to: recipient,
            refundTo: refundTo,
            inputAmount: 1 ether,
            outputAmount: 1000e18,
            deadline: block.timestamp + 1 hours,
            swapData: _encodeSwapData(
                abi.encodeWithSelector(MockDEXExchange.swap.selector, address(weth), address(outputToken), 1 ether)
            )
        });

        vm.expectRevert(SwapModuleBase.InvalidNativeSwap.selector);
        module.swapNative{value: 1 ether}(params);
    }

    // ============ Validation Tests ============

    function test_RevertWhen_InvalidSwapTarget() public {
        inputToken.mint(address(module), 1000e18);

        ISwapModule.SwapParams memory params = ISwapModule.SwapParams({
            swapType: ISwapModule.SwapType.ExactInput,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            to: recipient,
            refundTo: refundTo,
            inputAmount: 1000e18,
            outputAmount: 1000e18,
            deadline: block.timestamp + 1 hours,
            swapData: abi.encode(bytes(""), address(0xdead)) // Invalid target
        });

        vm.expectRevert(SwapModuleBase.InvalidSwapTarget.selector);
        module.swap(params);
    }

    function test_RevertWhen_SwapFails() public {
        inputToken.mint(address(module), 1000e18);

        exchange.setShouldFail(true);

        ISwapModule.SwapParams memory params = _createSwapParams(ISwapModule.SwapType.ExactInput, 1000e18, 1000e18);

        vm.expectRevert();
        module.swap(params);
    }

    // ============ Fuzz Tests ============

    function testFuzz_ExactInput_SwapAmounts(uint256 inputAmount, uint256 swapRateMultiplier) public {
        inputAmount = bound(inputAmount, 1e18, 1000000e18);
        swapRateMultiplier = bound(swapRateMultiplier, 0.1e18, 10e18);

        exchange.setSwapRate(swapRateMultiplier);

        uint256 expectedOutput = (inputAmount * swapRateMultiplier) / 1e18;

        inputToken.mint(address(module), inputAmount);

        ISwapModule.SwapParams memory params = _createSwapParams(
            ISwapModule.SwapType.ExactInput,
            inputAmount,
            0 // No min output for fuzz
        );

        ISwapModule.SwapResult memory result = module.swap(params);

        assertEq(result.inputAmountSpent, inputAmount);
        assertEq(result.outputAmountReceived, expectedOutput);
    }

    // ============ Helpers ============

    function _createSwapParams(ISwapModule.SwapType swapType, uint256 inputAmount, uint256 outputAmount)
        internal
        view
        returns (ISwapModule.SwapParams memory)
    {
        return ISwapModule.SwapParams({
            swapType: swapType,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            to: recipient,
            refundTo: refundTo,
            inputAmount: inputAmount,
            outputAmount: outputAmount,
            deadline: block.timestamp + 1 hours,
            swapData: _encodeSwapData(
                abi.encodeWithSelector(
                    MockDEXExchange.swap.selector, address(inputToken), address(outputToken), inputAmount
                )
            )
        });
    }

    function _createExactOutputParams(uint256 maxInput, uint256 exactOutput)
        internal
        view
        returns (ISwapModule.SwapParams memory)
    {
        return ISwapModule.SwapParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            to: recipient,
            refundTo: refundTo,
            inputAmount: maxInput,
            outputAmount: exactOutput,
            deadline: block.timestamp + 1 hours,
            swapData: _encodeSwapData(
                abi.encodeWithSelector(
                    MockDEXExchange.swapExactOutput.selector, address(inputToken), address(outputToken), exactOutput
                )
            )
        });
    }

    function _encodeSwapData(bytes memory callData) internal view returns (bytes memory) {
        return abi.encode(callData, address(exchange));
    }

    receive() external payable {}
}
