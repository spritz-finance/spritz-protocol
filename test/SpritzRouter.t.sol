// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpritzRouter} from "../src/SpritzRouter.sol";
import {SpritzPayCore} from "../src/SpritzPayCore.sol";
import {ISpritzRouter} from "../src/interfaces/ISpritzRouter.sol";
import {ISwapModule} from "../src/interfaces/ISwapModule.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20Mock} from "../src/test/ERC20Mock.sol";
import {ERC20PermitMock} from "../src/test/ERC20PermitMock.sol";
import {SwapModuleMock} from "../src/test/SwapModuleMock.sol";
import {RouterTestSetup} from "./helpers/TestSetup.sol";

contract SpritzRouterTest is RouterTestSetup {
    function setUp() public {
        _setupRouterTest();
    }

    // ============ Initialization Tests ============

    function test_SetUpState() public view {
        assertEq(address(router.core()), address(core));
        assertEq(router.owner(), admin);
        assertEq(address(router.swapModule()), address(swapModule));
    }

    function test_RevertWhen_ConstructedWithZeroCore() public {
        vm.expectRevert(SpritzRouter.ZeroAddress.selector);
        new SpritzRouter(address(0));
    }

    function test_RevertWhen_ConstructedWithEOACore() public {
        vm.expectRevert(SpritzRouter.NotAContract.selector);
        new SpritzRouter(makeAddr("eoa"));
    }

    function test_RevertWhen_InitializeWithZeroOwner() public {
        SpritzRouter newRouter = new SpritzRouter(address(core));
        vm.expectRevert(SpritzRouter.ZeroAddress.selector);
        newRouter.initialize(address(0));
    }

    function test_RevertWhen_InitializedTwice() public {
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        router.initialize(admin);
    }

    // ============ Admin Tests ============

    function test_SetSwapModule() public {
        SwapModuleMock newModule = new SwapModuleMock();

        vm.prank(admin);
        router.setSwapModule(address(newModule));

        assertEq(address(router.swapModule()), address(newModule));
    }

    function test_RevertWhen_NonOwnerSetsSwapModule() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        router.setSwapModule(address(swapModule));
    }

    function test_RevertWhen_SetSwapModuleToEOA() public {
        vm.prank(admin);
        vm.expectRevert(SpritzRouter.NotAContract.selector);
        router.setSwapModule(makeAddr("eoa"));
    }

    function test_SetSwapModuleToZero() public {
        vm.prank(admin);
        router.setSwapModule(address(0));
        assertEq(address(router.swapModule()), address(0));
    }

    // ============ Direct Payment Tests ============

    function test_Pay() public {
        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256("payment-123");

        paymentToken.mint(payer, amount);

        vm.prank(payer);
        paymentToken.approve(address(router), amount);

        vm.expectEmit(true, true, true, true);
        emit Payment(recipient, payer, address(paymentToken), amount, address(paymentToken), amount, paymentRef);

        vm.prank(payer);
        router.payWithToken(address(paymentToken), amount, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), amount);
        assertEq(paymentToken.balanceOf(payer), 0);
    }

    function test_RevertWhen_PayWithUnacceptedToken() public {
        uint256 amount = 1000e18;

        sourceToken.mint(payer, amount);

        vm.prank(payer);
        sourceToken.approve(address(router), amount);

        vm.expectRevert(abi.encodeWithSelector(SpritzPayCore.TokenNotAccepted.selector, address(sourceToken)));

        vm.prank(payer);
        router.payWithToken(address(sourceToken), amount, bytes32(0));
    }

    function test_PayWithPermit() public {
        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256("permit-payment");

        permitToken.mint(payer, amount);

        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            payer,
            payerPrivateKey,
            address(router),
            amount,
            block.timestamp + 1 hours
        );

        vm.expectEmit(true, true, true, true);
        emit Payment(recipient, payer, address(permitToken), amount, address(permitToken), amount, paymentRef);

        vm.prank(payer);
        router.payWithToken(address(permitToken), amount, paymentRef, permit);

        assertEq(permitToken.balanceOf(recipient), amount);
    }

    // ============ Swap Payment Tests ============

    function test_PayWithSwap_ExactOutput() public {
        uint256 sourceAmount = 1000e18;
        uint256 paymentAmount = 500e18;
        bytes32 paymentRef = keccak256("swap-payment");

        swapModule.setSwapRate(0.5e18);

        sourceToken.mint(payer, sourceAmount);

        vm.prank(payer);
        sourceToken.approve(address(router), sourceAmount);

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

    function test_PayWithSwap_ExactInput() public {
        uint256 sourceAmount = 1000e18;
        bytes32 paymentRef = keccak256("swap-exact-input");

        swapModule.setSwapRate(2e18);

        sourceToken.mint(payer, sourceAmount);

        vm.prank(payer);
        sourceToken.approve(address(router), sourceAmount);

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(sourceToken),
            sourceAmount: sourceAmount,
            paymentAmount: 0,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.prank(payer);
        router.payWithSwap(address(paymentToken), swapParams, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), sourceAmount * 2);
    }

    function test_PayWithSwap_RefundsExcess() public {
        uint256 maxInput = 1000e18;
        uint256 paymentAmount = 200e18;
        bytes32 paymentRef = keccak256("swap-refund");

        swapModule.setSwapRate(0.5e18);

        sourceToken.mint(payer, maxInput);

        vm.prank(payer);
        sourceToken.approve(address(router), maxInput);

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: maxInput,
            paymentAmount: paymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.prank(payer);
        router.payWithSwap(address(paymentToken), swapParams, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), paymentAmount);
        assertEq(sourceToken.balanceOf(payer), maxInput - 400e18);
    }

    function test_RevertWhen_SwapDeadlineExpired() public {
        sourceToken.mint(payer, 1000e18);

        vm.prank(payer);
        sourceToken.approve(address(router), 1000e18);

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: 1000e18,
            paymentAmount: 500e18,
            deadline: block.timestamp - 1,
            swapData: ""
        });

        vm.expectRevert(SpritzRouter.DeadlineExpired.selector);

        vm.prank(payer);
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));
    }

    // NOTE: InsufficientOutput validation is now handled by swap modules (SwapModuleBase)
    // See: test/OpenOceanModule.integration.t.sol and test/ParaSwapModule.integration.t.sol
    // for revert tests: test_ExactInput_RevertWhen_SlippageExceeded, test_ExactOutput_RevertWhen_ExceedsMaxInput

    function test_RevertWhen_SwapModuleNotSet() public {
        SpritzRouter newRouter = new SpritzRouter(address(core));
        newRouter.initialize(admin);

        sourceToken.mint(payer, 1000e18);

        vm.prank(payer);
        sourceToken.approve(address(newRouter), 1000e18);

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: 1000e18,
            paymentAmount: 500e18,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.expectRevert(SpritzRouter.SwapModuleNotSet.selector);

        vm.prank(payer);
        newRouter.payWithSwap(address(paymentToken), swapParams, bytes32(0));
    }

    function test_PayWithSwapPermit() public {
        uint256 sourceAmount = 1000e18;
        uint256 paymentAmount = 500e18;
        bytes32 paymentRef = keccak256("swap-permit");

        swapModule.setSwapRate(0.5e18);

        vm.prank(admin);
        core.addPaymentToken(address(paymentToken), recipient);

        ERC20PermitMock permitSourceToken = new ERC20PermitMock();
        permitSourceToken.mint(payer, sourceAmount);

        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitSourceToken),
            payer,
            payerPrivateKey,
            address(router),
            sourceAmount,
            block.timestamp + 1 hours
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(permitSourceToken),
            sourceAmount: sourceAmount,
            paymentAmount: paymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.prank(payer);
        router.payWithSwap(address(paymentToken), swapParams, paymentRef, permit);

        assertEq(paymentToken.balanceOf(recipient), paymentAmount);
    }

    // ============ Native Swap Tests ============

    function test_PayWithNativeSwap() public {
        uint256 ethAmount = 1 ether;
        uint256 paymentAmount = 2000e18;
        bytes32 paymentRef = keccak256("native-swap");

        swapModule.setSwapRate(2000e18);

        vm.deal(payer, ethAmount);

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(0),
            sourceAmount: ethAmount,
            paymentAmount: paymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.prank(payer);
        router.payWithNativeSwap{value: ethAmount}(address(paymentToken), swapParams, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), paymentAmount);
    }

    function test_RevertWhen_NativeSwapRefundFails() public {
        uint256 ethAmount = 1 ether;
        uint256 paymentAmount = 1000e18;

        swapModule.setSwapRate(2000e18);

        NoReceiveContract noReceive = new NoReceiveContract{value: ethAmount}(
            address(router),
            address(paymentToken),
            paymentAmount
        );

        vm.expectRevert("ETH refund failed");
        noReceive.attemptPayment();
    }

    function test_RevertWhen_PermitAmountInsufficient() public {
        uint256 paymentAmount = 1000e18;
        uint256 permitAmount = 500e18; // Less than payment amount
        bytes32 paymentRef = keccak256("insufficient-permit");

        permitToken.mint(payer, paymentAmount);

        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            payer,
            payerPrivateKey,
            address(router),
            permitAmount, // Permit for less than payment
            block.timestamp + 1 hours
        );

        vm.prank(payer);
        vm.expectRevert(); // Will revert on transferFrom due to insufficient allowance
        router.payWithToken(address(permitToken), paymentAmount, paymentRef, permit);
    }

    function test_RevertWhen_SwapPermitAmountInsufficient() public {
        uint256 sourceAmount = 1000e18;
        uint256 permitAmount = 500e18; // Less than source amount
        uint256 paymentAmount = 500e18;
        bytes32 paymentRef = keccak256("insufficient-swap-permit");

        swapModule.setSwapRate(0.5e18);

        ERC20PermitMock permitSourceToken = new ERC20PermitMock();
        permitSourceToken.mint(payer, sourceAmount);

        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitSourceToken),
            payer,
            payerPrivateKey,
            address(router),
            permitAmount, // Permit for less than source amount
            block.timestamp + 1 hours
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(permitSourceToken),
            sourceAmount: sourceAmount,
            paymentAmount: paymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.prank(payer);
        vm.expectRevert(); // Will revert on transferFrom due to insufficient allowance
        router.payWithSwap(address(paymentToken), swapParams, paymentRef, permit);
    }

    // ============ Meta-Transaction Tests ============

    function test_PayWithTokenOnBehalf() public {
        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256("on-behalf-payment");
        address relayer = makeAddr("relayer");

        permitToken.mint(payer, amount);

        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            payer,
            payerPrivateKey,
            address(router),
            amount,
            block.timestamp + 1 hours
        );

        vm.expectEmit(true, true, true, true);
        emit Payment(recipient, payer, address(permitToken), amount, address(permitToken), amount, paymentRef);

        vm.prank(relayer);
        router.payWithTokenOnBehalf(payer, address(permitToken), amount, paymentRef, permit);

        assertEq(permitToken.balanceOf(recipient), amount);
        assertEq(permitToken.balanceOf(payer), 0);
    }

    function test_PayWithSwapOnBehalf() public {
        uint256 sourceAmount = 1000e18;
        uint256 paymentAmount = 500e18;
        bytes32 paymentRef = keccak256("swap-on-behalf");
        address relayer = makeAddr("relayer");

        swapModule.setSwapRate(0.5e18);

        ERC20PermitMock permitSourceToken = new ERC20PermitMock();
        permitSourceToken.mint(payer, sourceAmount);

        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitSourceToken),
            payer,
            payerPrivateKey,
            address(router),
            sourceAmount,
            block.timestamp + 1 hours
        );

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(permitSourceToken),
            sourceAmount: sourceAmount,
            paymentAmount: paymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.prank(relayer);
        router.payWithSwapOnBehalf(payer, address(paymentToken), swapParams, paymentRef, permit);

        assertEq(paymentToken.balanceOf(recipient), paymentAmount);
    }

    // ============ Sweep Tests ============

    function test_Sweep() public {
        uint256 amount = 1000e18;
        address treasury = makeAddr("treasury");

        paymentToken.mint(address(router), amount);

        vm.prank(admin);
        router.sweep(address(paymentToken), treasury);

        assertEq(paymentToken.balanceOf(treasury), amount);
        assertEq(paymentToken.balanceOf(address(router)), 0);
    }

    function test_Sweep_ZeroBalance() public {
        address treasury = makeAddr("treasury");

        vm.prank(admin);
        router.sweep(address(paymentToken), treasury);

        assertEq(paymentToken.balanceOf(treasury), 0);
    }

    function test_RevertWhen_NonOwnerSweeps() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        router.sweep(address(paymentToken), address(this));
    }

    // ============ Fuzz Tests ============

    function testFuzz_Pay(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        bytes32 paymentRef = keccak256(abi.encode(amount));

        paymentToken.mint(payer, amount);

        vm.prank(payer);
        paymentToken.approve(address(router), amount);

        vm.prank(payer);
        router.payWithToken(address(paymentToken), amount, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), amount);
    }

    // ============ Edge Case Tests ============

    function test_PayWithZeroAmount() public {
        bytes32 paymentRef = keccak256("zero-amount");

        vm.prank(payer);
        paymentToken.approve(address(router), 0);

        vm.prank(payer);
        router.payWithToken(address(paymentToken), 0, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), 0);
    }

    function testFuzz_PayPreservesBalances(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        bytes32 paymentRef = keccak256(abi.encode("preserves", amount));

        paymentToken.mint(payer, amount);
        uint256 payerBalBefore = paymentToken.balanceOf(payer);
        uint256 recipientBalBefore = paymentToken.balanceOf(recipient);

        vm.prank(payer);
        paymentToken.approve(address(router), amount);

        vm.prank(payer);
        router.payWithToken(address(paymentToken), amount, paymentRef);

        assertEq(paymentToken.balanceOf(payer), payerBalBefore - amount);
        assertEq(paymentToken.balanceOf(recipient), recipientBalBefore + amount);
        // Router should never hold tokens
        assertEq(paymentToken.balanceOf(address(router)), 0);
    }

    function test_RevertWhen_PayWithNonContractToken() public {
        address fakeToken = makeAddr("not-a-contract");
        uint256 amount = 1000e18;

        vm.prank(payer);
        vm.expectRevert();
        router.payWithToken(fakeToken, amount, bytes32(0));
    }

    function testFuzz_FailedPaymentPreservesUserBalance(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        // Use unaccepted token
        sourceToken.mint(payer, amount);

        uint256 payerBalanceBefore = sourceToken.balanceOf(payer);

        vm.prank(payer);
        sourceToken.approve(address(router), amount);

        // This should revert because sourceToken is not accepted
        vm.prank(payer);
        vm.expectRevert();
        router.payWithToken(address(sourceToken), amount, bytes32(0));

        // Payer's balance should be unchanged
        assertEq(sourceToken.balanceOf(payer), payerBalanceBefore, "User balance should be preserved on revert");
        assertEq(sourceToken.balanceOf(address(router)), 0, "Router should have no tokens");
        assertEq(sourceToken.balanceOf(address(core)), 0, "Core should have no tokens");
    }

    function testFuzz_FailedSwapPreservesUserBalance(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        sourceToken.mint(payer, amount);

        uint256 payerBalanceBefore = sourceToken.balanceOf(payer);

        vm.prank(payer);
        sourceToken.approve(address(router), amount);

        // Use unaccepted payment token to force revert after swap
        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: amount,
            paymentAmount: amount / 2,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        // This should revert because alternativeToken is not accepted
        ERC20Mock unacceptedToken = new ERC20Mock();

        vm.prank(payer);
        vm.expectRevert();
        router.payWithSwap(address(unacceptedToken), swapParams, bytes32(0));

        // Payer's balance should be unchanged
        assertEq(sourceToken.balanceOf(payer), payerBalanceBefore, "User balance should be preserved on revert");
        assertEq(sourceToken.balanceOf(address(router)), 0, "Router should have no tokens");
    }

    // ============ Permit Fuzz Tests ============

    function testFuzz_PayWithPermit(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        bytes32 paymentRef = keccak256(abi.encode("fuzz-permit", amount));

        permitToken.mint(payer, amount);

        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            payer,
            payerPrivateKey,
            address(router),
            amount,
            block.timestamp + 1 hours
        );

        vm.prank(payer);
        router.payWithToken(address(permitToken), amount, paymentRef, permit);

        assertEq(permitToken.balanceOf(recipient), amount);
        assertEq(permitToken.balanceOf(payer), 0);
    }

    function testFuzz_RevertWhen_PermitWrongSigner(uint256 wrongKeyOffset) public {
        wrongKeyOffset = bound(wrongKeyOffset, 1, 1000);
        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256("wrong-signer");

        permitToken.mint(payer, amount);

        // Sign with wrong private key
        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            payer,
            payerPrivateKey + wrongKeyOffset, // Wrong key
            address(router),
            amount,
            block.timestamp + 1 hours
        );

        vm.prank(payer);
        vm.expectRevert();
        router.payWithToken(address(permitToken), amount, paymentRef, permit);
    }

    function testFuzz_RevertWhen_PermitExpired(uint256 timeInPast) public {
        timeInPast = bound(timeInPast, 1, block.timestamp); // Can't go below 0
        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256("expired-permit");

        permitToken.mint(payer, amount);

        // Permit with deadline in the past
        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            payer,
            payerPrivateKey,
            address(router),
            amount,
            block.timestamp - timeInPast // Expired
        );

        vm.prank(payer);
        vm.expectRevert();
        router.payWithToken(address(permitToken), amount, paymentRef, permit);
    }

    function test_RevertWhen_PermitWrongSpender() public {
        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256("wrong-spender");
        address wrongSpender = makeAddr("wrongSpender");

        permitToken.mint(payer, amount);

        // Sign permit for wrong spender
        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            payer,
            payerPrivateKey,
            wrongSpender, // Wrong spender - not the router
            amount,
            block.timestamp + 1 hours
        );

        vm.prank(payer);
        vm.expectRevert();
        router.payWithToken(address(permitToken), amount, paymentRef, permit);
    }

    function test_RevertWhen_PermitReplay() public {
        uint256 amount = 1000e18;
        bytes32 paymentRef1 = keccak256("first-payment");
        bytes32 paymentRef2 = keccak256("second-payment");

        permitToken.mint(payer, amount * 2);

        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            payer,
            payerPrivateKey,
            address(router),
            amount,
            block.timestamp + 1 hours
        );

        // First use succeeds
        vm.prank(payer);
        router.payWithToken(address(permitToken), amount, paymentRef1, permit);

        // Replay with same permit fails (nonce already used)
        vm.prank(payer);
        vm.expectRevert();
        router.payWithToken(address(permitToken), amount, paymentRef2, permit);
    }

    function testFuzz_PayWithTokenOnBehalf_DifferentRelayer(address relayer) public {
        vm.assume(relayer != address(0));
        vm.assume(relayer != payer);

        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256(abi.encode("relayer", relayer));

        permitToken.mint(payer, amount);

        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            payer,
            payerPrivateKey,
            address(router),
            amount,
            block.timestamp + 1 hours
        );

        // Any relayer can submit
        vm.prank(relayer);
        router.payWithTokenOnBehalf(payer, address(permitToken), amount, paymentRef, permit);

        assertEq(permitToken.balanceOf(recipient), amount);
        assertEq(permitToken.balanceOf(payer), 0);
    }

}

contract SpritzRouterInvariantTest is Test {
    SpritzRouter public router;
    SpritzPayCore public core;
    SpritzRouterHandler public handler;

    ERC20Mock public paymentToken;
    address public admin;
    address public recipient;

    function setUp() public {
        admin = makeAddr("admin");
        recipient = makeAddr("recipient");

        core = new SpritzPayCore();
        core.initialize(admin);

        router = new SpritzRouter(address(core));
        router.initialize(admin);

        paymentToken = new ERC20Mock();

        vm.prank(admin);
        core.addPaymentToken(address(paymentToken), recipient);

        handler = new SpritzRouterHandler(router, core, paymentToken);

        targetContract(address(handler));
    }

    function invariant_RouterNeverHoldsTokens() public view {
        assertEq(
            paymentToken.balanceOf(address(router)),
            0,
            "Router should never hold tokens"
        );
    }

    function invariant_CoreNeverHoldsTokens() public view {
        assertEq(
            paymentToken.balanceOf(address(core)),
            0,
            "Core should never hold tokens after payment"
        );
    }

    function invariant_CoreImmutable() public view {
        assertEq(
            address(router.core()),
            address(core),
            "Core address should never change"
        );
    }
}

contract SpritzRouterHandler is Test {
    SpritzRouter public router;
    SpritzPayCore public core;
    ERC20Mock public paymentToken;

    constructor(SpritzRouter _router, SpritzPayCore _core, ERC20Mock _paymentToken) {
        router = _router;
        core = _core;
        paymentToken = _paymentToken;
    }

    function pay(uint256 amount) public {
        amount = bound(amount, 0, 1000e18);

        address payer = makeAddr("payer");
        paymentToken.mint(payer, amount);

        vm.prank(payer);
        paymentToken.approve(address(router), amount);

        vm.prank(payer);
        router.payWithToken(address(paymentToken), amount, bytes32(uint256(amount)));
    }
}

/// @dev Helper contract that cannot receive ETH - used to test refund failure scenarios
contract NoReceiveContract {
    SpritzRouter public router;
    address public paymentToken;
    uint256 public paymentAmount;

    constructor(address _router, address _paymentToken, uint256 _paymentAmount) payable {
        router = SpritzRouter(payable(_router));
        paymentToken = _paymentToken;
        paymentAmount = _paymentAmount;
    }

    function attemptPayment() external {
        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(0),
            sourceAmount: address(this).balance,
            paymentAmount: paymentAmount,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        router.payWithNativeSwap{value: address(this).balance}(
            paymentToken,
            swapParams,
            keccak256("no-receive-test")
        );
    }

    // Intentionally NO receive() or fallback() function
}
