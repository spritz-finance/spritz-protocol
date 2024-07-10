// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/SpritzPayCore.sol";
import "../src/test/ERC20Mock.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SpritzPayCoreTest is Test {
    SpritzPayCore public spritzPay;
    address public admin;
    address public payer;
    address public paymentRecipient;
    address public alternativeRecipient;
    IERC20 public paymentToken;
    IERC20 public alternativeToken;

    function setUp() public {
        admin = address(1);
        payer = address(2);
        paymentRecipient = address(3);
        alternativeRecipient = address(4);

        spritzPay = new SpritzPayCore();
        spritzPay.initialize(admin);

        paymentToken = IERC20(address(new ERC20Mock()));
        alternativeToken = IERC20(address(new ERC20Mock()));
    }

    function testAddPaymentToken() public {
        vm.startPrank(admin);

        assertEq(spritzPay.acceptedPaymentTokens().length, 0);

        spritzPay.addPaymentToken(address(paymentToken), paymentRecipient);

        assertEq(spritzPay.acceptedPaymentTokens().length, 1);
        assertEq(spritzPay.acceptedPaymentTokens()[0], address(paymentToken));
        assertEq(
            spritzPay.paymentRecipient(address(paymentToken)),
            paymentRecipient
        );

        vm.stopPrank();
    }

    function testUpdatePaymentRecipient() public {
        vm.startPrank(admin);

        spritzPay.addPaymentToken(address(paymentToken), paymentRecipient);
        assertEq(
            spritzPay.paymentRecipient(address(paymentToken)),
            paymentRecipient
        );

        spritzPay.addPaymentToken(address(paymentToken), alternativeRecipient);
        assertEq(
            spritzPay.paymentRecipient(address(paymentToken)),
            alternativeRecipient
        );

        vm.stopPrank();
    }

    function testNonAdminCannotAddPaymentToken() public {
        vm.expectRevert(
            "AccessControl: account 0x0000000000000000000000000000000000000001 is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
        );
        spritzPay.addPaymentToken(address(paymentToken), paymentRecipient);
    }

    function testRemovePaymentToken() public {
        vm.startPrank(admin);

        spritzPay.addPaymentToken(address(paymentToken), paymentRecipient);
        assertEq(spritzPay.acceptedPaymentTokens().length, 1);

        spritzPay.removePaymentToken(address(paymentToken));
        assertEq(spritzPay.acceptedPaymentTokens().length, 0);
        assertEq(spritzPay.paymentRecipient(address(paymentToken)), address(0));

        vm.stopPrank();
    }

    function testIsAcceptedToken() public {
        vm.startPrank(admin);

        spritzPay.addPaymentToken(address(paymentToken), paymentRecipient);

        assertTrue(spritzPay.isAcceptedToken(address(paymentToken)));
        assertFalse(spritzPay.isAcceptedToken(address(this)));

        vm.stopPrank();
    }

    function testCannotPayWithUnacceptedToken() public {
        vm.expectRevert("TokenNotAccepted");
        spritzPay.pay(
            payer,
            address(paymentToken),
            1000,
            address(paymentToken),
            1000,
            keccak256("0x1234")
        );
    }

    function testPayWithAcceptedToken() public {
        vm.startPrank(admin);
        spritzPay.addPaymentToken(address(paymentToken), paymentRecipient);
        vm.stopPrank();

        vm.mockCall(
            address(paymentToken),
            abi.encodeWithSelector(IERC20.transferFrom.selector),
            abi.encode(true)
        );

        spritzPay.pay(
            payer,
            address(paymentToken),
            1000,
            address(paymentToken),
            1000,
            keccak256("0x1234")
        );

        // Verify the transfer was called
        vm.expectCall(
            address(paymentToken),
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                payer,
                paymentRecipient,
                1000
            )
        );
    }
}
