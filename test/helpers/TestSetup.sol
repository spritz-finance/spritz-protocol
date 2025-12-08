// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpritzRouter} from "../../src/SpritzRouter.sol";
import {SpritzPayCore} from "../../src/SpritzPayCore.sol";
import {ERC20Mock} from "../../src/test/ERC20Mock.sol";
import {ERC20PermitMock} from "../../src/test/ERC20PermitMock.sol";
import {SwapModuleMock} from "../../src/test/SwapModuleMock.sol";
import {PermitHelper} from "./PermitHelper.sol";

/// @title BaseTestSetup
/// @notice Base test contract with common setup for Core and Router tests
abstract contract BaseTestSetup is PermitHelper {
    SpritzPayCore public core;
    SpritzRouter public router;

    address public admin;
    address public recipient;

    ERC20Mock public paymentToken;

    event Payment(
        address to,
        address indexed from,
        address indexed sourceToken,
        uint256 sourceTokenAmount,
        address paymentToken,
        uint256 paymentTokenAmount,
        bytes32 indexed paymentReference
    );

    function _setupCore() internal {
        admin = makeAddr("admin");
        recipient = makeAddr("recipient");

        core = new SpritzPayCore();
        core.initialize(admin);

        paymentToken = new ERC20Mock();

        vm.prank(admin);
        core.addPaymentToken(address(paymentToken), recipient);

        vm.label(address(core), "Core");
        vm.label(address(paymentToken), "PaymentToken");
    }

    function _setupRouter() internal {
        router = new SpritzRouter(address(core));
        router.initialize(admin);

        vm.label(address(router), "Router");
    }
}

/// @title RouterTestSetup
/// @notice Extended setup for Router tests with swap module and source token
abstract contract RouterTestSetup is BaseTestSetup {
    SwapModuleMock public swapModule;
    ERC20Mock public sourceToken;
    ERC20PermitMock public permitToken;

    address public payer;
    uint256 public payerPrivateKey;

    function _setupRouterTest() internal {
        _setupCore();
        _setupRouter();

        (payer, payerPrivateKey) = makeAddrAndKey("payer");

        swapModule = new SwapModuleMock();
        sourceToken = new ERC20Mock();
        permitToken = new ERC20PermitMock();

        vm.prank(admin);
        router.setSwapModule(address(swapModule));

        vm.prank(admin);
        core.addPaymentToken(address(permitToken), recipient);

        vm.label(address(swapModule), "SwapModule");
        vm.label(address(sourceToken), "SourceToken");
        vm.label(address(permitToken), "PermitToken");
    }
}
