// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpritzRouter} from "../../src/SpritzRouter.sol";
import {SpritzPayCore} from "../../src/SpritzPayCore.sol";
import {ISpritzRouter} from "../../src/interfaces/ISpritzRouter.sol";
import {ISwapModule} from "../../src/interfaces/ISwapModule.sol";
import {ParaSwapModule} from "../../src/modules/ParaSwapModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ParaSwap Fork Tests
/// @notice End-to-end tests using real ParaSwap API on Base fork
/// @dev Run with: forge test --match-path test/fork/ParaSwap.fork.t.sol --ffi -vvv
///      These tests require --ffi flag and RPC_KEY env var for Alchemy
///      Tests may be slow (~60s each) due to RPC calls and API requests
///      Note: test_NativeSwap_ExactOutput_WithRefund may fail due to ParaSwap BUY order
///      mechanics with native ETH - this is a known limitation of the API flow
///      Run individual tests for faster feedback:
///      forge test --match-test test_ExactInput_WethToUsdc --match-path test/fork/ParaSwap.fork.t.sol --ffi -vv
contract ParaSwapForkTest is Test {
    // Base chain constants
    uint256 constant BASE_CHAIN_ID = 8453;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant PARASWAP_REGISTRY = 0x7E31B336F9E8bA52ba3c4ac861b033Ba90900bb3;

    SpritzRouter public router;
    SpritzPayCore public core;
    ParaSwapModule public swapModule;

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
        // Fork Base - use base_local for speed when anvil is running, otherwise base
        // Start anvil with: anvil --fork-url "https://base-mainnet.g.alchemy.com/v2/$RPC_KEY" --port 8545
        try vm.createSelectFork("base_local") {} catch {
            vm.createSelectFork("base");
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

        swapModule = new ParaSwapModule(PARASWAP_REGISTRY, WETH);
        router.setSwapModule(address(swapModule));

        // Setup USDC as accepted payment token
        core.addPaymentToken(USDC, recipient);

        vm.stopPrank();
    }

    /// @notice Test exact input swap: WETH -> USDC payment
    function test_ExactInput_WethToUsdc() public {
        uint256 wethAmount = 0.01 ether; // 0.01 WETH

        // Get swap calldata from ParaSwap API via FFI
        (bytes memory swapData, uint256 expectedOut) = _getParaSwapSwap(
            WETH,
            18,
            USDC,
            6,
            wethAmount,
            "SELL",
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

        bytes32 ref = keccak256("test-paraswap-exact-in");

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

        // Get BUY quote from ParaSwap (exact output)
        (bytes memory swapData, uint256 srcAmount) = _getParaSwapSwap(
            WETH,
            18,
            USDC,
            6,
            usdcAmount,
            "BUY",
            address(swapModule)
        );

        // Add 10% buffer for price movement
        uint256 maxWethInput = (srcAmount * 110) / 100;

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

        bytes32 ref = keccak256("test-paraswap-exact-out");

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
        (bytes memory swapData, uint256 expectedOut) = _getParaSwapSwap(
            WETH,
            18,
            USDC,
            6,
            ethAmount,
            "SELL",
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

        bytes32 ref = keccak256("test-paraswap-native");

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

        // Get BUY quote for exact output
        (bytes memory swapData, uint256 srcAmount) = _getParaSwapSwap(
            WETH,
            18,
            USDC,
            6,
            usdcAmount,
            "BUY",
            address(swapModule)
        );

        // Send 20% more than needed
        uint256 ethToSend = (srcAmount * 120) / 100;

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

        bytes32 ref = keccak256("test-paraswap-native-exact-out");

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

    function _getParaSwapSwap(
        address srcToken,
        uint8 srcDecimals,
        address destToken,
        uint8 destDecimals,
        uint256 amount,
        string memory side,
        address account
    ) internal returns (bytes memory swapData, uint256 resultAmount) {
        string[] memory cmd = new string[](11);
        cmd[0] = "bun";
        cmd[1] = "scripts/src/get-swap.ts";
        cmd[2] = "paraswap";
        cmd[3] = vm.toString(BASE_CHAIN_ID);
        cmd[4] = vm.toString(srcToken);
        cmd[5] = vm.toString(uint256(srcDecimals));
        cmd[6] = vm.toString(destToken);
        cmd[7] = vm.toString(uint256(destDecimals));
        cmd[8] = vm.toString(amount);
        cmd[9] = side;
        cmd[10] = vm.toString(account);

        bytes memory result = vm.ffi(cmd);
        string memory json = string(result);

        // Parse JSON response
        bool success = vm.parseJsonBool(json, ".success");
        require(success, string.concat("ParaSwap API call failed: ", json));

        swapData = vm.parseJsonBytes(json, ".swapData");

        // Return srcAmount for BUY orders (what we need to spend)
        // Return destAmount for SELL orders (what we expect to receive)
        if (keccak256(bytes(side)) == keccak256(bytes("BUY"))) {
            resultAmount = vm.parseJsonUint(json, ".srcAmount");
        } else {
            resultAmount = vm.parseJsonUint(json, ".destAmount");
        }
    }
}
