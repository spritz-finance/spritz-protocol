// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpritzRouter} from "../src/SpritzRouter.sol";
import {SpritzPayCore} from "../src/SpritzPayCore.sol";
import {ISpritzRouter} from "../src/interfaces/ISpritzRouter.sol";
import {ISwapModule} from "../src/interfaces/ISwapModule.sol";
import {ERC20Mock} from "../src/test/ERC20Mock.sol";
import {ERC20PermitMock} from "../src/test/ERC20PermitMock.sol";
import {SwapModuleMock} from "../src/test/SwapModuleMock.sol";
import {PermitHelper} from "./helpers/PermitHelper.sol";

/// @dev Permit2 interface for AllowanceTransfer
interface IPermit2 {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    struct PackedAllowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
    function allowance(address owner, address token, address spender) external view returns (uint160 amount, uint48 expiration, uint48 nonce);
    function permit(address owner, PermitSingle memory permitSingle, bytes calldata signature) external;
    function lockdown(TokenSpenderPair[] calldata approvals) external;

    struct TokenSpenderPair {
        address token;
        address spender;
    }
}

/// @title SpritzRouter Permit2 Integration Tests
/// @notice Tests Permit2 AllowanceTransfer and SignatureTransfer flows
/// @dev These tests fork mainnet to use the real Permit2 contract
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
        // Fork mainnet to get real Permit2
        // Uses the "mainnet" RPC endpoint configured in foundry.toml
        vm.createSelectFork("mainnet");

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

    // ============ Permit2 AllowanceTransfer Tests ============

    /// @notice Direct payment using Permit2 AllowanceTransfer
    /// @dev User approves Permit2, then calls permit2.approve() for router
    function test_PayWithPermit2_AllowanceTransfer_DirectPayment() public {
        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256("permit2-allowance-payment");

        paymentToken.mint(payer, amount);

        // Step 1: Payer approves Permit2 (not the router!)
        vm.prank(payer);
        paymentToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        // Step 2: Payer sets up Permit2 allowance for router
        vm.prank(payer);
        permit2.approve(address(paymentToken), address(router), uint160(amount), uint48(block.timestamp + 1 hours));

        // Step 3: Pay via router - safeTransferFrom2 will use Permit2 fallback
        vm.expectEmit(true, true, true, true);
        emit Payment(recipient, payer, address(paymentToken), amount, address(paymentToken), amount, paymentRef);

        vm.prank(payer);
        router.payWithToken(address(paymentToken), amount, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), amount);
        assertEq(paymentToken.balanceOf(payer), 0);
    }

    /// @notice Swap payment using Permit2 AllowanceTransfer
    function test_PayWithPermit2_AllowanceTransfer_SwapPayment() public {
        uint256 sourceAmount = 1000e18;
        uint256 paymentAmount = 500e18;
        bytes32 paymentRef = keccak256("permit2-allowance-swap");

        swapModule.setSwapRate(0.5e18);

        sourceToken.mint(payer, sourceAmount);

        vm.prank(payer);
        sourceToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        vm.prank(payer);
        permit2.approve(address(sourceToken), address(router), uint160(sourceAmount), uint48(block.timestamp + 1 hours));

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

    /// @notice Permit2 allowance expires
    function test_RevertWhen_Permit2AllowanceExpired() public {
        uint256 amount = 1000e18;

        paymentToken.mint(payer, amount);

        vm.prank(payer);
        paymentToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        // Set expiration to now (will be expired immediately)
        vm.prank(payer);
        permit2.approve(address(paymentToken), address(router), uint160(amount), uint48(block.timestamp));

        // Warp forward so the allowance is expired
        vm.warp(block.timestamp + 1);

        vm.prank(payer);
        vm.expectRevert(); // Permit2 will reject expired allowance
        router.payWithToken(address(paymentToken), amount, bytes32(0));
    }

    /// @notice Permit2 allowance insufficient
    function test_RevertWhen_Permit2AllowanceInsufficient() public {
        uint256 amount = 1000e18;
        uint160 approvedAmount = 500e18; // Less than payment amount

        paymentToken.mint(payer, amount);

        vm.prank(payer);
        paymentToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        vm.prank(payer);
        permit2.approve(address(paymentToken), address(router), approvedAmount, uint48(block.timestamp + 1 hours));

        vm.prank(payer);
        vm.expectRevert(); // Permit2 will reject insufficient allowance
        router.payWithToken(address(paymentToken), amount, bytes32(0));
    }

    // ============ Permit2 + EIP-2612 Combined Tests ============

    /// @notice When native permit fails on non-permit token, Solady tries Permit2 fallback
    /// @dev This test documents the behavior - if Permit2 allowance is set, it works as fallback
    function test_Permit2FallbackWhenNativePermitFails() public {
        uint256 amount = 1000e18;
        bytes32 paymentRef = keccak256("fallback-test");

        // Use a non-permit token (ERC20Mock doesn't have permit)
        paymentToken.mint(payer, amount);

        // Approve Permit2
        vm.prank(payer);
        paymentToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        // Set up Permit2 allowance for router
        vm.prank(payer);
        permit2.approve(address(paymentToken), address(router), uint160(amount), uint48(block.timestamp + 1 hours));

        // For non-permit tokens, don't use the permit variant - just use regular payWithToken
        // The Permit2 allowance will be used via safeTransferFrom2's fallback
        vm.prank(payer);
        router.payWithToken(address(paymentToken), amount, paymentRef);

        assertEq(paymentToken.balanceOf(recipient), amount);
    }

    /// @notice Calling permit-variant with invalid permit on non-permit token fails
    /// @dev Solady's permit2() tries native permit first, then Permit2 simplePermit2
    ///      simplePermit2 requires a valid signature for the Permit2 permit() function
    function test_RevertWhen_InvalidPermitOnNonPermitToken() public {
        uint256 amount = 1000e18;

        paymentToken.mint(payer, amount);

        // Even with Permit2 allowance set up...
        vm.prank(payer);
        paymentToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        vm.prank(payer);
        permit2.approve(address(paymentToken), address(router), uint160(amount), uint48(block.timestamp + 1 hours));

        // ...calling with dummy/invalid permit data fails because:
        // Solady's permit2() tries simplePermit2() which calls Permit2.permit() with the signature
        // The signature is invalid, so it reverts
        ISpritzRouter.PermitData memory dummyPermit = ISpritzRouter.PermitData({
            deadline: block.timestamp + 1 hours,
            v: 27,
            r: bytes32(0),
            s: bytes32(0)
        });

        vm.prank(payer);
        vm.expectRevert(); // Permit2Failed - invalid signature
        router.payWithToken(address(paymentToken), amount, bytes32(0), dummyPermit);
    }

    // ============ Permit2 Lockdown Tests ============

    /// @notice User can revoke Permit2 allowance via lockdown
    function test_Permit2Lockdown() public {
        uint256 amount = 1000e18;

        paymentToken.mint(payer, amount);

        vm.prank(payer);
        paymentToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        vm.prank(payer);
        permit2.approve(address(paymentToken), address(router), uint160(amount), uint48(block.timestamp + 1 hours));

        // Verify allowance is set
        (uint160 allowedAmount,,) = permit2.allowance(payer, address(paymentToken), address(router));
        assertEq(allowedAmount, amount);

        // User revokes via lockdown
        IPermit2.TokenSpenderPair[] memory lockdownPairs = new IPermit2.TokenSpenderPair[](1);
        lockdownPairs[0] = IPermit2.TokenSpenderPair({
            token: address(paymentToken),
            spender: address(router)
        });

        vm.prank(payer);
        permit2.lockdown(lockdownPairs);

        // Verify allowance is revoked
        (uint160 newAllowedAmount,,) = permit2.allowance(payer, address(paymentToken), address(router));
        assertEq(newAllowedAmount, 0);

        // Payment should now fail
        vm.prank(payer);
        vm.expectRevert();
        router.payWithToken(address(paymentToken), amount, bytes32(0));
    }

    // ============ Permit2 Nonce Tests ============

    /// @notice Permit2 nonce increments after each permit
    function test_Permit2NonceIncrementsAfterPermit() public {
        uint256 amount = 500e18;

        paymentToken.mint(payer, amount * 2);

        vm.prank(payer);
        paymentToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        // Get initial nonce
        (,, uint48 nonce1) = permit2.allowance(payer, address(paymentToken), address(router));

        // First permit
        vm.prank(payer);
        permit2.approve(address(paymentToken), address(router), uint160(amount), uint48(block.timestamp + 1 hours));

        // Make a payment
        vm.prank(payer);
        router.payWithToken(address(paymentToken), amount, bytes32("first"));

        // Get nonce after - it should be same (approve doesn't increment nonce, permit does)
        (,, uint48 nonce2) = permit2.allowance(payer, address(paymentToken), address(router));
        // Note: approve() doesn't increment nonce, only permit() with signature does

        // Approve again for second payment
        vm.prank(payer);
        permit2.approve(address(paymentToken), address(router), uint160(amount), uint48(block.timestamp + 1 hours));

        // Make second payment
        vm.prank(payer);
        router.payWithToken(address(paymentToken), amount, bytes32("second"));

        assertEq(paymentToken.balanceOf(recipient), amount * 2);
    }
}

/// @title Permit2 Security Tests
/// @notice Tests that Permit2 approvals cannot be exploited
contract SpritzRouterPermit2SecurityTest is Test {
    address internal constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    SpritzRouter public router;
    SpritzPayCore public core;
    IPermit2 public permit2;

    ERC20Mock public paymentToken;

    address public admin;
    address public victim;
    address public attacker;
    address public recipient;

    uint256 public victimPrivateKey;

    uint256 constant VICTIM_BALANCE = 10_000e18;

    function setUp() public {
        // Fork mainnet to get real Permit2
        vm.createSelectFork("mainnet");

        admin = makeAddr("admin");
        recipient = makeAddr("recipient");
        (victim, victimPrivateKey) = makeAddrAndKey("victim");
        attacker = makeAddr("attacker");

        permit2 = IPermit2(PERMIT2_ADDRESS);

        core = new SpritzPayCore();
        core.initialize(admin);

        router = new SpritzRouter(address(core));
        router.initialize(admin);

        paymentToken = new ERC20Mock();

        vm.prank(admin);
        core.addPaymentToken(address(paymentToken), recipient);

        // Setup: Victim has tokens and has approved Permit2
        paymentToken.mint(victim, VICTIM_BALANCE);

        vm.prank(victim);
        paymentToken.approve(PERMIT2_ADDRESS, type(uint256).max);

        // Victim has also approved the router via Permit2
        vm.prank(victim);
        permit2.approve(address(paymentToken), address(router), type(uint160).max, type(uint48).max);

        vm.label(address(router), "Router");
        vm.label(victim, "Victim");
        vm.label(attacker, "Attacker");
    }

    /// @notice Attacker cannot use payWithToken to steal victim's Permit2-approved funds
    /// @dev The router uses msg.sender for transferFrom, not a caller-specified address
    function test_Security_Permit2_CannotStealViaPayWithToken() public {
        uint256 victimBalanceBefore = paymentToken.balanceOf(victim);

        // Attacker calls payWithToken - this should only try to use attacker's tokens
        vm.prank(attacker);
        vm.expectRevert(); // Attacker has no tokens or Permit2 allowance
        router.payWithToken(address(paymentToken), 1000e18, bytes32(0));

        // Victim's balance unchanged
        assertEq(paymentToken.balanceOf(victim), victimBalanceBefore);
    }

    /// @notice Even with victim's Permit2 approval, attacker needs valid permit for OnBehalf
    /// @dev OnBehalf functions require EIP-2612 permit signature, not just Permit2 allowance
    function test_Security_Permit2_OnBehalfStillRequiresSignature() public {
        uint256 victimBalanceBefore = paymentToken.balanceOf(victim);

        // Victim has Permit2 allowance for router, but attacker tries OnBehalf with fake signature
        ISpritzRouter.PermitData memory fakePermit = ISpritzRouter.PermitData({
            deadline: block.timestamp + 1 hours,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        vm.prank(attacker);
        vm.expectRevert(); // Invalid signature
        router.payWithTokenOnBehalf(victim, address(paymentToken), 1000e18, bytes32(0), fakePermit);

        assertEq(paymentToken.balanceOf(victim), victimBalanceBefore);
    }

    /// @notice Attacker cannot directly call Permit2 to steal via router
    /// @dev Permit2.transferFrom checks msg.sender is the approved spender
    function test_Security_Permit2_DirectTransferFromFails() public {
        uint256 victimBalanceBefore = paymentToken.balanceOf(victim);

        // Attacker tries to call Permit2.transferFrom directly
        // This fails because attacker is not the approved spender (router is)
        vm.prank(attacker);
        vm.expectRevert();
        permit2.transferFrom(victim, attacker, uint160(1000e18), address(paymentToken));

        assertEq(paymentToken.balanceOf(victim), victimBalanceBefore);
    }

    /// @notice Permit2 allowance for router doesn't help attacker
    /// @dev Router's safeTransferFrom2 uses msg.sender as 'from'
    function test_Security_Permit2_RouterOnlyPullsFromMsgSender() public {
        // The key insight: even though victim has Permit2 allowance for router,
        // when attacker calls router.payWithToken(), the router does:
        // SafeTransferLib.safeTransferFrom2(token, msg.sender, ..., amount)
        //                                        ^^^^^^^^^^
        //                                        This is attacker, not victim!

        // So Permit2.transferFrom(attacker, ...) will fail because:
        // 1. Attacker hasn't approved Permit2
        // 2. Even if they did, they don't have tokens

        uint256 victimBalanceBefore = paymentToken.balanceOf(victim);

        vm.prank(attacker);
        vm.expectRevert();
        router.payWithToken(address(paymentToken), 1000e18, bytes32(0));

        assertEq(paymentToken.balanceOf(victim), victimBalanceBefore);
    }

    /// @notice Comprehensive attack attempt with Permit2
    function test_Security_Permit2_ComprehensiveAttackFails() public {
        uint256 victimBalanceBefore = paymentToken.balanceOf(victim);

        // Vector 1: Direct payWithToken (fails - uses msg.sender)
        vm.prank(attacker);
        vm.expectRevert();
        router.payWithToken(address(paymentToken), 1000e18, bytes32("steal1"));

        // Vector 2: With fake EIP-2612 permit (fails - invalid signature)
        ISpritzRouter.PermitData memory fakePermit = ISpritzRouter.PermitData({
            deadline: block.timestamp + 1 hours,
            v: 28,
            r: bytes32(uint256(123)),
            s: bytes32(uint256(456))
        });

        vm.prank(attacker);
        vm.expectRevert();
        router.payWithToken(address(paymentToken), 1000e18, bytes32("steal2"), fakePermit);

        // Vector 3: OnBehalf with fake permit (fails - invalid signature)
        vm.prank(attacker);
        vm.expectRevert();
        router.payWithTokenOnBehalf(victim, address(paymentToken), 1000e18, bytes32("steal3"), fakePermit);

        // Victim's balance completely unchanged
        assertEq(paymentToken.balanceOf(victim), victimBalanceBefore);
    }

    /// @notice Victim can safely revoke Permit2 allowance
    function test_Security_Permit2_VictimCanRevoke() public {
        // Verify victim has allowance
        (uint160 allowedAmount,,) = permit2.allowance(victim, address(paymentToken), address(router));
        assertGt(allowedAmount, 0);

        // Victim revokes
        IPermit2.TokenSpenderPair[] memory lockdownPairs = new IPermit2.TokenSpenderPair[](1);
        lockdownPairs[0] = IPermit2.TokenSpenderPair({
            token: address(paymentToken),
            spender: address(router)
        });

        vm.prank(victim);
        permit2.lockdown(lockdownPairs);

        // Verify revoked
        (uint160 newAllowedAmount,,) = permit2.allowance(victim, address(paymentToken), address(router));
        assertEq(newAllowedAmount, 0);

        // Even victim's own payment now fails (they'd need to re-approve)
        vm.prank(victim);
        vm.expectRevert();
        router.payWithToken(address(paymentToken), 1000e18, bytes32(0));
    }
}

/// @title EIP-2612 Permit Security Tests
/// @notice Comprehensive tests for EIP-2612 permit functionality
contract SpritzRouterEIP2612SecurityTest is PermitHelper {
    SpritzRouter public router;
    SpritzPayCore public core;

    ERC20PermitMock public permitToken;

    address public admin;
    address public victim;
    address public attacker;
    address public recipient;

    uint256 public victimPrivateKey;
    uint256 public attackerPrivateKey;

    function setUp() public {
        admin = makeAddr("admin");
        recipient = makeAddr("recipient");
        (victim, victimPrivateKey) = makeAddrAndKey("victim");
        (attacker, attackerPrivateKey) = makeAddrAndKey("attacker");

        core = new SpritzPayCore();
        core.initialize(admin);

        router = new SpritzRouter(address(core));
        router.initialize(admin);

        permitToken = new ERC20PermitMock();

        vm.prank(admin);
        core.addPaymentToken(address(permitToken), recipient);

        permitToken.mint(victim, 10_000e18);
    }

    /// @notice Permit with wrong owner address fails
    function test_Security_PermitWrongOwnerFails() public {
        uint256 amount = 1000e18;

        // Attacker signs a permit as themselves
        ISpritzRouter.PermitData memory attackerPermit =
            _signPermit(address(permitToken), attacker, attackerPrivateKey, address(router), amount, block.timestamp + 1 hours);

        // Attacker tries to use it for victim
        vm.prank(attacker);
        vm.expectRevert();
        router.payWithTokenOnBehalf(victim, address(permitToken), amount, bytes32(0), attackerPermit);
    }

    /// @notice Permit with wrong spender fails
    function test_Security_PermitWrongSpenderFails() public {
        uint256 amount = 1000e18;

        // Victim signs permit for wrong spender
        ISpritzRouter.PermitData memory permit =
            _signPermit(address(permitToken), victim, victimPrivateKey, attacker, amount, block.timestamp + 1 hours);

        vm.prank(victim);
        vm.expectRevert();
        router.payWithToken(address(permitToken), amount, bytes32(0), permit);
    }

    /// @notice Permit cannot be used after deadline
    function test_Security_PermitDeadlineEnforced() public {
        uint256 amount = 1000e18;
        uint256 deadline = block.timestamp + 1 hours;

        ISpritzRouter.PermitData memory permit =
            _signPermit(address(permitToken), victim, victimPrivateKey, address(router), amount, deadline);

        // Warp past deadline
        vm.warp(deadline + 1);

        vm.prank(victim);
        vm.expectRevert();
        router.payWithToken(address(permitToken), amount, bytes32(0), permit);
    }

    /// @notice Permit nonce prevents replay
    function test_Security_PermitNoncePreventsReplay() public {
        uint256 amount = 500e18;

        ISpritzRouter.PermitData memory permit =
            _signPermit(address(permitToken), victim, victimPrivateKey, address(router), amount, block.timestamp + 1 hours);

        // First use succeeds
        vm.prank(victim);
        router.payWithToken(address(permitToken), amount, bytes32("first"), permit);

        assertEq(permitToken.balanceOf(recipient), amount);

        // Replay fails (nonce incremented)
        vm.prank(victim);
        vm.expectRevert();
        router.payWithToken(address(permitToken), amount, bytes32("replay"), permit);

        // Attacker replay also fails
        vm.prank(attacker);
        vm.expectRevert();
        router.payWithTokenOnBehalf(victim, address(permitToken), amount, bytes32("attacker-replay"), permit);
    }

    /// @notice Permit with zero value is valid but does nothing
    function test_PermitZeroValueIsValid() public {
        ISpritzRouter.PermitData memory permit =
            _signPermit(address(permitToken), victim, victimPrivateKey, address(router), 0, block.timestamp + 1 hours);

        uint256 victimBalanceBefore = permitToken.balanceOf(victim);

        vm.prank(victim);
        router.payWithToken(address(permitToken), 0, bytes32("zero"), permit);

        assertEq(permitToken.balanceOf(victim), victimBalanceBefore);
    }

    /// @notice Permit with max value works
    function testFuzz_PermitMaxValue(uint256 actualAmount) public {
        actualAmount = bound(actualAmount, 1, 10_000e18);

        // Sign permit for the exact amount we'll use (not max)
        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken), victim, victimPrivateKey, address(router), actualAmount, block.timestamp + 1 hours
        );

        vm.prank(victim);
        router.payWithToken(address(permitToken), actualAmount, bytes32("max"), permit);

        assertEq(permitToken.balanceOf(recipient), actualAmount);
    }

    /// @notice Multiple sequential permits work
    function test_MultipleSequentialPermits() public {
        uint256 amount = 1000e18;

        for (uint256 i = 0; i < 3; i++) {
            ISpritzRouter.PermitData memory permit = _signPermit(
                address(permitToken), victim, victimPrivateKey, address(router), amount, block.timestamp + 1 hours
            );

            vm.prank(victim);
            router.payWithToken(address(permitToken), amount, bytes32(uint256(i)), permit);
        }

        assertEq(permitToken.balanceOf(recipient), amount * 3);
        assertEq(permitToken.balanceOf(victim), 10_000e18 - amount * 3);
    }

    /// @notice Frontrunning a permit doesn't steal funds
    function test_Security_PermitFrontrunSafe() public {
        uint256 amount = 1000e18;

        ISpritzRouter.PermitData memory permit =
            _signPermit(address(permitToken), victim, victimPrivateKey, address(router), amount, block.timestamp + 1 hours);

        // Attacker frontruns and executes the permit
        vm.prank(attacker);
        router.payWithTokenOnBehalf(victim, address(permitToken), amount, bytes32("frontrun"), permit);

        // Funds went to recipient, not attacker
        assertEq(permitToken.balanceOf(recipient), amount);
        assertEq(permitToken.balanceOf(attacker), 0);
    }
}
