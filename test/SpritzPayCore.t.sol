// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpritzPayCore} from "../src/SpritzPayCore.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20Mock} from "../src/test/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SpritzPayCoreTest is Test {
    SpritzPayCore public spritzPay;
    ERC20Mock public paymentToken;
    ERC20Mock public alternativeToken;

    address public admin;
    address public payer;
    address public recipient;
    address public alternativeRecipient;

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
        admin = makeAddr("admin");
        payer = makeAddr("payer");
        recipient = makeAddr("recipient");
        alternativeRecipient = makeAddr("alternativeRecipient");

        spritzPay = new SpritzPayCore();
        spritzPay.initialize(admin);

        paymentToken = new ERC20Mock();
        alternativeToken = new ERC20Mock();

        vm.label(address(spritzPay), "SpritzPayCore");
        vm.label(address(paymentToken), "PaymentToken");
        vm.label(address(alternativeToken), "AlternativeToken");
    }

    function test_SetUpState() public view {
        assertEq(spritzPay.owner(), admin);
        assertEq(spritzPay.acceptedPaymentTokens().length, 0);
    }

    // ============ Initialization Tests ============

    function test_RevertWhen_InitializedTwice() public {
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        spritzPay.initialize(admin);
    }

    function test_RevertWhen_InitializedByAnyone() public {
        SpritzPayCore newContract = new SpritzPayCore();
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        newContract.initialize(attacker);

        assertEq(newContract.owner(), attacker);
    }

    // ============ Payment Token Management Tests ============

    function test_AddPaymentToken() public {
        vm.prank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);

        assertEq(spritzPay.acceptedPaymentTokens().length, 1);
        assertEq(spritzPay.acceptedPaymentTokens()[0], address(paymentToken));
        assertEq(spritzPay.paymentRecipient(address(paymentToken)), recipient);
        assertTrue(spritzPay.isAcceptedToken(address(paymentToken)));
    }

    function test_AddMultiplePaymentTokens() public {
        vm.startPrank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);
        spritzPay.addPaymentToken(address(alternativeToken), alternativeRecipient);
        vm.stopPrank();

        assertEq(spritzPay.acceptedPaymentTokens().length, 2);
        assertTrue(spritzPay.isAcceptedToken(address(paymentToken)));
        assertTrue(spritzPay.isAcceptedToken(address(alternativeToken)));
    }

    function test_UpdatePaymentRecipient() public {
        vm.startPrank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);
        spritzPay.addPaymentToken(address(paymentToken), alternativeRecipient);
        vm.stopPrank();

        assertEq(spritzPay.paymentRecipient(address(paymentToken)), alternativeRecipient);
        assertEq(spritzPay.acceptedPaymentTokens().length, 1, "Should not duplicate token");
    }

    function test_RemovePaymentToken() public {
        vm.startPrank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);
        spritzPay.removePaymentToken(address(paymentToken));
        vm.stopPrank();

        assertEq(spritzPay.acceptedPaymentTokens().length, 0);
        assertEq(spritzPay.paymentRecipient(address(paymentToken)), address(0));
        assertFalse(spritzPay.isAcceptedToken(address(paymentToken)));
    }

    function test_RevertWhen_AddPaymentTokenWithZeroAddress() public {
        vm.startPrank(admin);

        vm.expectRevert(SpritzPayCore.ZeroAddress.selector);
        spritzPay.addPaymentToken(address(0), recipient);

        vm.expectRevert(SpritzPayCore.ZeroAddress.selector);
        spritzPay.addPaymentToken(address(paymentToken), address(0));

        vm.stopPrank();
    }

    function test_RevertWhen_NonOwnerAddsPaymentToken() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        spritzPay.addPaymentToken(address(paymentToken), recipient);
    }

    function test_RevertWhen_NonOwnerRemovesPaymentToken() public {
        vm.prank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);

        vm.expectRevert(Ownable.Unauthorized.selector);
        spritzPay.removePaymentToken(address(paymentToken));
    }

    // ============ Pay Function Tests ============

    function test_Pay() public {
        uint256 amount = 1000;
        bytes32 paymentRef = keccak256("payment-123");

        vm.prank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);

        paymentToken.mint(address(spritzPay), amount);

        spritzPay.pay(payer, address(paymentToken), amount, address(paymentToken), amount, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), amount);
        assertEq(paymentToken.balanceOf(address(spritzPay)), 0);
    }

    function test_Pay_EmitsPaymentEvent() public {
        uint256 amount = 1000;
        bytes32 paymentRef = keccak256("payment-123");

        vm.prank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);

        paymentToken.mint(address(spritzPay), amount);

        vm.expectEmit(true, true, true, true);
        emit Payment(recipient, payer, address(paymentToken), amount, address(paymentToken), amount, paymentRef);

        spritzPay.pay(payer, address(paymentToken), amount, address(paymentToken), amount, paymentRef);
    }

    function test_Pay_WithDifferentSourceToken() public {
        uint256 paymentAmount = 1000;
        uint256 sourceAmount = 500;
        bytes32 paymentRef = keccak256("swap-payment");

        vm.prank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);

        paymentToken.mint(address(spritzPay), paymentAmount);

        vm.expectEmit(true, true, true, true);
        emit Payment(
            recipient,
            payer,
            address(alternativeToken),
            sourceAmount,
            address(paymentToken),
            paymentAmount,
            paymentRef
        );

        spritzPay.pay(
            payer,
            address(paymentToken),
            paymentAmount,
            address(alternativeToken),
            sourceAmount,
            paymentRef
        );
    }

    function test_RevertWhen_PayWithUnacceptedToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(SpritzPayCore.TokenNotAccepted.selector, address(paymentToken))
        );
        spritzPay.pay(payer, address(paymentToken), 1000, address(paymentToken), 1000, bytes32(0));
    }

    function test_RevertWhen_PayWithInsufficientBalance() public {
        vm.prank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);

        vm.expectRevert();
        spritzPay.pay(payer, address(paymentToken), 1000, address(paymentToken), 1000, bytes32(0));
    }

    function test_RevertWhen_PayWithRemovedToken() public {
        vm.startPrank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);
        spritzPay.removePaymentToken(address(paymentToken));
        vm.stopPrank();

        paymentToken.mint(address(spritzPay), 1000);

        vm.expectRevert(
            abi.encodeWithSelector(SpritzPayCore.TokenNotAccepted.selector, address(paymentToken))
        );
        spritzPay.pay(payer, address(paymentToken), 1000, address(paymentToken), 1000, bytes32(0));
    }

    // ============ Sweep Tests ============

    function test_Sweep() public {
        uint256 amount = 5000;
        address sweepTo = makeAddr("treasury");

        paymentToken.mint(address(spritzPay), amount);

        vm.prank(admin);
        spritzPay.sweep(address(paymentToken), sweepTo);

        assertEq(paymentToken.balanceOf(sweepTo), amount);
        assertEq(paymentToken.balanceOf(address(spritzPay)), 0);
    }

    function test_Sweep_WithZeroBalance() public {
        address sweepTo = makeAddr("treasury");

        vm.prank(admin);
        spritzPay.sweep(address(paymentToken), sweepTo);

        assertEq(paymentToken.balanceOf(sweepTo), 0);
    }

    function test_RevertWhen_NonOwnerSweeps() public {
        paymentToken.mint(address(spritzPay), 1000);

        vm.expectRevert(Ownable.Unauthorized.selector);
        spritzPay.sweep(address(paymentToken), address(this));
    }

    // ============ Ownership Tests ============

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(admin);
        spritzPay.transferOwnership(newOwner);

        assertEq(spritzPay.owner(), newOwner);
    }

    function test_RevertWhen_NonOwnerTransfersOwnership() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        spritzPay.transferOwnership(address(this));
    }

    // ============ Fuzz Tests ============

    function testFuzz_Pay(uint256 amount, bytes32 paymentRef) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.prank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);

        paymentToken.mint(address(spritzPay), amount);

        uint256 recipientBalanceBefore = paymentToken.balanceOf(recipient);

        spritzPay.pay(payer, address(paymentToken), amount, address(paymentToken), amount, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), recipientBalanceBefore + amount);
        assertEq(paymentToken.balanceOf(address(spritzPay)), 0);
    }

    function testFuzz_Pay_EmitsCorrectEvent(
        address caller,
        uint256 paymentAmount,
        uint256 sourceAmount,
        bytes32 paymentRef
    ) public {
        vm.assume(caller != address(0));
        paymentAmount = bound(paymentAmount, 1, type(uint128).max);

        vm.prank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);

        paymentToken.mint(address(spritzPay), paymentAmount);

        vm.expectEmit(true, true, true, true);
        emit Payment(
            recipient,
            caller,
            address(alternativeToken),
            sourceAmount,
            address(paymentToken),
            paymentAmount,
            paymentRef
        );

        spritzPay.pay(
            caller,
            address(paymentToken),
            paymentAmount,
            address(alternativeToken),
            sourceAmount,
            paymentRef
        );
    }

    function testFuzz_Sweep(uint256 amount) public {
        amount = bound(amount, 0, type(uint128).max);
        address sweepTo = makeAddr("treasury");

        paymentToken.mint(address(spritzPay), amount);

        vm.prank(admin);
        spritzPay.sweep(address(paymentToken), sweepTo);

        assertEq(paymentToken.balanceOf(sweepTo), amount);
        assertEq(paymentToken.balanceOf(address(spritzPay)), 0);
    }

    function testFuzz_AddPaymentToken(address token, address tokenRecipient) public {
        vm.assume(token != address(0));
        vm.assume(tokenRecipient != address(0));
        // Solady EnumerableSetLib uses this as a zero sentinel
        vm.assume(token != address(0x0000000000000000000000fbb67FDa52D4Bfb8Bf));

        vm.prank(admin);
        spritzPay.addPaymentToken(token, tokenRecipient);

        assertTrue(spritzPay.isAcceptedToken(token));
        assertEq(spritzPay.paymentRecipient(token), tokenRecipient);
    }
}

contract SpritzPayCoreInvariantTest is Test {
    SpritzPayCore public spritzPay;
    ERC20Mock public paymentToken;
    address public admin;
    address public recipient;

    function setUp() public {
        admin = makeAddr("admin");
        recipient = makeAddr("recipient");

        spritzPay = new SpritzPayCore();
        spritzPay.initialize(admin);

        paymentToken = new ERC20Mock();

        vm.prank(admin);
        spritzPay.addPaymentToken(address(paymentToken), recipient);

        targetContract(address(spritzPay));
    }

    function invariant_PaymentTokenHasRecipient() public view {
        address[] memory tokens = spritzPay.acceptedPaymentTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            assertTrue(
                spritzPay.paymentRecipient(tokens[i]) != address(0),
                "Accepted token must have recipient"
            );
        }
    }

}
