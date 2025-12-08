// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpritzRouter} from "../../src/SpritzRouter.sol";
import {SpritzPayCore} from "../../src/SpritzPayCore.sol";
import {ISpritzRouter} from "../../src/interfaces/ISpritzRouter.sol";
import {ISwapModule} from "../../src/interfaces/ISwapModule.sol";
import {OpenOceanModule} from "../../src/modules/OpenOceanModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title OpenOcean Fork Tests (Ethereum Mainnet)
/// @notice End-to-end tests using real OpenOcean API on Ethereum mainnet fork
/// @dev Run with: forge test --match-path test/fork/OpenOcean.mainnet.t.sol --ffi -vvv
///      These tests require --ffi flag and RPC_KEY env var for Alchemy
///      Ethereum mainnet has 12s blocks (vs Base's 2s) for more stable fork testing
///      NOTE: Run tests individually to avoid RPC rate limiting:
///      forge test --match-test test_ExactInput_WethToUsdc --match-path test/fork/OpenOcean.mainnet.t.sol --ffi -vv
contract OpenOceanMainnetTest is Test {
    // Ethereum mainnet constants
    uint256 constant ETH_CHAIN_ID = 1;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant OPENOCEAN_EXCHANGE = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    SpritzRouter public router;
    SpritzPayCore public core;
    OpenOceanModule public swapModule;

    address public admin;
    address public payer;
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

    function setUp() public {
        // Fork Ethereum mainnet - use mainnet_local for speed when anvil is running
        try vm.createSelectFork("mainnet_local") {} catch {
            vm.createSelectFork("mainnet");
        }

        admin = makeAddr("admin");
        payer = makeAddr("payer");
        recipient = makeAddr("recipient");

        // Deploy contracts
        vm.startPrank(admin);

        core = new SpritzPayCore();
        core.initialize(admin);

        router = new SpritzRouter(address(core));
        router.initialize(admin);

        swapModule = new OpenOceanModule(OPENOCEAN_EXCHANGE, WETH);
        router.setSwapModule(address(swapModule));

        // Setup USDC as accepted payment token
        core.addPaymentToken(USDC, recipient);

        vm.stopPrank();
    }

    /// @notice Test exact input swap: WETH -> USDC payment
    function test_ExactInput_WethToUsdc() public {
        uint256 wethAmount = 0.01 ether; // 0.01 WETH

        // Get swap calldata from OpenOcean API via FFI
        (bytes memory swapData, uint256 expectedOut) = _getOpenOceanSwap(
            WETH,
            USDC,
            wethAmount,
            address(swapModule)
        );

        // Fund payer with WETH
        deal(WETH, payer, wethAmount);

        // Payer approves router
        vm.startPrank(payer);
        IERC20(WETH).approve(address(router), wethAmount);

        // Calculate min output with 5% slippage tolerance for test
        uint256 minOutput = (expectedOut * 95) / 100;

        ISpritzRouter.SwapPaymentParams memory swap = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: WETH,
            sourceAmount: wethAmount,
            paymentAmount: minOutput,
            deadline: block.timestamp + 300,
            swapData: swapData
        });

        bytes32 ref = keccak256("test-exact-in");

        uint256 recipientBefore = IERC20(USDC).balanceOf(recipient);

        router.payWithSwap(USDC, swap, ref);

        uint256 recipientAfter = IERC20(USDC).balanceOf(recipient);
        uint256 received = recipientAfter - recipientBefore;

        vm.stopPrank();

        // Verify payment was received
        assertGt(received, 0, "Should receive USDC");
        assertGe(received, minOutput, "Should meet minimum output");

        // Verify payer spent WETH
        assertEq(IERC20(WETH).balanceOf(payer), 0, "Payer should have spent all WETH");
    }

    /// @notice Test exact output swap: WETH -> exact USDC amount
    function test_ExactOutput_WethToUsdc() public {
        uint256 usdcAmount = 10e6; // 10 USDC (6 decimals)

        // First get reverse quote to know how much WETH we need
        uint256 wethNeeded = _getOpenOceanReverseQuote(WETH, USDC, usdcAmount);

        // Add 10% buffer for price movement
        uint256 maxWethInput = (wethNeeded * 110) / 100;

        // Get swap calldata for the buffered amount
        (bytes memory swapData,) = _getOpenOceanSwap(
            WETH,
            USDC,
            maxWethInput,
            address(swapModule)
        );

        // Fund payer with max WETH
        deal(WETH, payer, maxWethInput);

        vm.startPrank(payer);
        IERC20(WETH).approve(address(router), maxWethInput);

        ISpritzRouter.SwapPaymentParams memory swap = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: WETH,
            sourceAmount: maxWethInput,
            paymentAmount: usdcAmount,
            deadline: block.timestamp + 300,
            swapData: swapData
        });

        bytes32 ref = keccak256("test-exact-out");

        uint256 recipientBefore = IERC20(USDC).balanceOf(recipient);
        uint256 payerWethBefore = maxWethInput;

        router.payWithSwap(USDC, swap, ref);

        uint256 recipientAfter = IERC20(USDC).balanceOf(recipient);
        uint256 payerWethAfter = IERC20(WETH).balanceOf(payer);

        vm.stopPrank();

        uint256 received = recipientAfter - recipientBefore;
        uint256 spent = payerWethBefore - payerWethAfter;

        // Verify exact output received (or more due to swap mechanics)
        assertGe(received, usdcAmount, "Should receive at least exact amount");

        // Verify payer got refund (didn't spend max)
        assertLt(spent, maxWethInput, "Should not spend max input");
    }

    /// @notice Test native ETH swap: ETH -> USDC payment
    function test_NativeSwap_EthToUsdc() public {
        uint256 ethAmount = 0.01 ether;

        // Get swap calldata - use WETH address for quote but will send native ETH
        (bytes memory swapData, uint256 expectedOut) = _getOpenOceanSwap(
            WETH,
            USDC,
            ethAmount,
            address(swapModule)
        );

        // Fund payer with native ETH
        vm.deal(payer, ethAmount);

        vm.startPrank(payer);

        uint256 minOutput = (expectedOut * 95) / 100;

        ISpritzRouter.SwapPaymentParams memory swap = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(0), // Native ETH
            sourceAmount: ethAmount,
            paymentAmount: minOutput,
            deadline: block.timestamp + 300,
            swapData: swapData
        });

        bytes32 ref = keccak256("test-native");

        uint256 recipientBefore = IERC20(USDC).balanceOf(recipient);

        router.payWithNativeSwap{value: ethAmount}(USDC, swap, ref);

        uint256 recipientAfter = IERC20(USDC).balanceOf(recipient);
        uint256 received = recipientAfter - recipientBefore;

        vm.stopPrank();

        // Verify payment was received
        assertGt(received, 0, "Should receive USDC");
        assertGe(received, minOutput, "Should meet minimum output");

        // Verify payer spent ETH
        assertEq(payer.balance, 0, "Payer should have spent all ETH");
    }

    /// @notice Test native ETH exact output with refund
    function test_NativeSwap_ExactOutput_WithRefund() public {
        uint256 usdcAmount = 10e6; // 10 USDC

        // Get reverse quote
        uint256 ethNeeded = _getOpenOceanReverseQuote(WETH, USDC, usdcAmount);

        // Send 20% more than needed
        uint256 ethToSend = (ethNeeded * 120) / 100;

        // Get swap calldata
        (bytes memory swapData,) = _getOpenOceanSwap(
            WETH,
            USDC,
            ethToSend,
            address(swapModule)
        );

        vm.deal(payer, ethToSend);

        vm.startPrank(payer);

        ISpritzRouter.SwapPaymentParams memory swap = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(0),
            sourceAmount: ethToSend,
            paymentAmount: usdcAmount,
            deadline: block.timestamp + 300,
            swapData: swapData
        });

        bytes32 ref = keccak256("test-native-exact-out");

        uint256 recipientBefore = IERC20(USDC).balanceOf(recipient);

        router.payWithNativeSwap{value: ethToSend}(USDC, swap, ref);

        uint256 recipientAfter = IERC20(USDC).balanceOf(recipient);
        uint256 payerEthAfter = payer.balance;

        vm.stopPrank();

        uint256 received = recipientAfter - recipientBefore;

        // Verify exact output received
        assertGe(received, usdcAmount, "Should receive at least exact amount");

        // Verify payer got ETH refund
        assertGt(payerEthAfter, 0, "Payer should receive ETH refund");
    }

    // ============ FFI Helpers ============

    function _getOpenOceanSwap(
        address inToken,
        address outToken,
        uint256 amount,
        address account
    ) internal returns (bytes memory swapData, uint256 expectedOut) {
        string[] memory cmd = new string[](7);
        cmd[0] = "bun";
        cmd[1] = "scripts/src/get-swap.ts";
        cmd[2] = "openocean";
        cmd[3] = vm.toString(ETH_CHAIN_ID);
        cmd[4] = vm.toString(inToken);
        cmd[5] = vm.toString(outToken);
        cmd[6] = vm.toString(amount);

        // Create array with 8 elements for account
        string[] memory fullCmd = new string[](8);
        for (uint i = 0; i < 7; i++) {
            fullCmd[i] = cmd[i];
        }
        fullCmd[7] = vm.toString(account);

        bytes memory result = vm.ffi(fullCmd);
        string memory json = string(result);

        // Parse JSON response
        bool success = vm.parseJsonBool(json, ".success");
        require(success, "OpenOcean API call failed");

        swapData = vm.parseJsonBytes(json, ".swapData");
        expectedOut = vm.parseJsonUint(json, ".outAmount");
    }

    function _getOpenOceanReverseQuote(
        address inToken,
        address outToken,
        uint256 outAmount
    ) internal returns (uint256 inAmount) {
        string[] memory cmd = new string[](7);
        cmd[0] = "bun";
        cmd[1] = "scripts/src/get-swap.ts";
        cmd[2] = "openocean-reverse";
        cmd[3] = vm.toString(ETH_CHAIN_ID);
        cmd[4] = vm.toString(inToken);
        cmd[5] = vm.toString(outToken);
        cmd[6] = vm.toString(outAmount);

        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        bool success = vm.parseJsonBool(json, ".success");
        require(success, "OpenOcean reverse quote failed");

        inAmount = vm.parseJsonUint(json, ".inAmount");
    }
}
