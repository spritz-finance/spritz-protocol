// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpritzRouter} from "../src/SpritzRouter.sol";
import {SpritzPayCore} from "../src/SpritzPayCore.sol";
import {ISpritzRouter} from "../src/interfaces/ISpritzRouter.sol";
import {ISwapModule} from "../src/interfaces/ISwapModule.sol";
import {ERC20Mock} from "../src/test/ERC20Mock.sol";
import {SwapModuleMock} from "../src/test/SwapModuleMock.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

contract SpritzRouterPermit2Test is Test {
    address internal constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    SpritzRouter public router;
    SpritzPayCore public core;
    SwapModuleMock public swapModule;
    IPermit2 public permit2;

    ERC20Mock public paymentToken;
    ERC20Mock public sourceToken;

    address public admin;
    address public payer;
    address public recipient;

    uint256 public payerPrivateKey;

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
        // Fork mainnet to get real Permit2 (latest block)
        vm.createSelectFork("https://eth.llamarpc.com");

        admin = makeAddr("admin");
        recipient = makeAddr("recipient");
        (payer, payerPrivateKey) = makeAddrAndKey("payer");

        permit2 = IPermit2(PERMIT2_ADDRESS);

        core = new SpritzPayCore();
        core.initialize(admin);

        router = new SpritzRouter(address(core));
        router.initialize(admin);

        swapModule = new SwapModuleMock();

        vm.prank(admin);
        router.setSwapModule(address(swapModule));

        paymentToken = new ERC20Mock();
        sourceToken = new ERC20Mock();

        vm.prank(admin);
        core.addPaymentToken(address(paymentToken), recipient);

        vm.label(address(router), "Router");
        vm.label(address(core), "Core");
        vm.label(PERMIT2_ADDRESS, "Permit2");
        vm.label(address(paymentToken), "PaymentToken");
        vm.label(address(sourceToken), "SourceToken");
    }

    function test_PayWithPermit2_DirectPayment() public {
        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256("permit2-payment");

        // Mint tokens to payer
        paymentToken.mint(payer, amount);

        // Payer approves Permit2 (not the router!)
        vm.prank(payer);
        paymentToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        // Payer sets up Permit2 allowance for router
        vm.prank(payer);
        permit2.approve(address(paymentToken), address(router), uint160(amount), uint48(block.timestamp + 1 hours));

        // With Permit2 AllowanceTransfer, user has already approved via permit2.approve()
        // So we use payWithToken (not payWithPermit) - the safeTransferFrom2 will use Permit2
        vm.expectEmit(true, true, true, true);
        emit Payment(recipient, payer, address(paymentToken), amount, address(paymentToken), amount, paymentRef);

        vm.prank(payer);
        router.payWithToken(address(paymentToken), amount, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), amount);
        assertEq(paymentToken.balanceOf(payer), 0);
    }

    function test_PayWithPermit2_SwapPayment() public {
        uint256 sourceAmount = 1000e18;
        uint256 paymentAmount = 500e18;
        bytes32 paymentRef = keccak256("permit2-swap");

        swapModule.setSwapRate(0.5e18);

        // Mint source tokens to payer
        sourceToken.mint(payer, sourceAmount);

        // Payer approves Permit2
        vm.prank(payer);
        sourceToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        // Payer sets up Permit2 allowance for router
        vm.prank(payer);
        permit2.approve(address(sourceToken), address(router), uint160(sourceAmount), uint48(block.timestamp + 1 hours));

        // With Permit2 AllowanceTransfer, user has already approved via permit2.approve()
        // So we use payWithSwap (not payWithSwapPermit) - the safeTransferFrom2 will use Permit2
        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: sourceAmount,
            paymentAmount: paymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.prank(payer);
        router.payWithSwap(address(paymentToken), swapParams, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), paymentAmount);
    }
}
