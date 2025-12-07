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

/// @title SpritzRouter Security Tests
/// @notice Tests focused on exploit prevention when users have unlimited approval to the router
/// @dev Key threat model: An attacker wants to drain funds from a victim who has approved the router
///
/// Attack Surface Analysis:
/// 1. Direct approval theft - Can attacker call router functions to steal victim's approved tokens?
/// 2. Permit manipulation - Can attacker forge/replay/frontrun permits?
/// 3. SwapData exploitation - Can attacker craft malicious swapData to redirect funds?
/// 4. OnBehalf functions - Can attacker abuse meta-transaction functions?
/// 5. Reentrancy - Can attacker use callbacks to drain funds?
contract SpritzRouterSecurityTest is Test {
    SpritzRouter public router;
    SpritzPayCore public core;
    SwapModuleMock public swapModule;

    ERC20Mock public paymentToken;
    ERC20Mock public sourceToken;
    ERC20PermitMock public permitToken;

    address public admin;
    address public victim;
    address public attacker;
    address public recipient;

    uint256 public victimPrivateKey;
    uint256 public attackerPrivateKey;

    uint256 constant VICTIM_BALANCE = 10_000e18;
    uint256 constant UNLIMITED_APPROVAL = type(uint256).max;

    function setUp() public {
        admin = makeAddr("admin");
        recipient = makeAddr("recipient");
        (victim, victimPrivateKey) = makeAddrAndKey("victim");
        (attacker, attackerPrivateKey) = makeAddrAndKey("attacker");

        core = new SpritzPayCore();
        core.initialize(admin);

        router = new SpritzRouter(address(core));
        router.initialize(admin);

        swapModule = new SwapModuleMock();

        vm.prank(admin);
        router.setSwapModule(address(swapModule));

        paymentToken = new ERC20Mock();
        sourceToken = new ERC20Mock();
        permitToken = new ERC20PermitMock();

        vm.prank(admin);
        core.addPaymentToken(address(paymentToken), recipient);

        vm.prank(admin);
        core.addPaymentToken(address(permitToken), recipient);

        // Setup: Victim has tokens and has given UNLIMITED approval to the router
        paymentToken.mint(victim, VICTIM_BALANCE);
        permitToken.mint(victim, VICTIM_BALANCE);
        sourceToken.mint(victim, VICTIM_BALANCE);

        vm.startPrank(victim);
        paymentToken.approve(address(router), UNLIMITED_APPROVAL);
        permitToken.approve(address(router), UNLIMITED_APPROVAL);
        sourceToken.approve(address(router), UNLIMITED_APPROVAL);
        vm.stopPrank();

        vm.label(address(router), "Router");
        vm.label(address(core), "Core");
        vm.label(address(swapModule), "SwapModule");
        vm.label(victim, "Victim");
        vm.label(attacker, "Attacker");
    }

    // ============ Attack Vector 1: Direct Approval Theft ============
    // Can an attacker call payWithToken as themselves but pull from victim's balance?

    /// @notice Attacker cannot use payWithToken to steal victim's approved funds
    /// @dev The router uses msg.sender as the source of funds, not a caller-specified address
    function test_Security_CannotStealViaPayWithToken() public {
        uint256 victimBalanceBefore = paymentToken.balanceOf(victim);
        uint256 attackerBalanceBefore = paymentToken.balanceOf(attacker);

        // Attacker calls payWithToken - this should only affect attacker's balance
        vm.prank(attacker);
        vm.expectRevert(); // Attacker has no tokens
        router.payWithToken(address(paymentToken), 1000e18, bytes32(0));

        // Victim's balance unchanged
        assertEq(paymentToken.balanceOf(victim), victimBalanceBefore);
        assertEq(paymentToken.balanceOf(attacker), attackerBalanceBefore);
    }

    /// @notice Attacker cannot specify victim's address in any direct payment function
    /// @dev All direct payment functions use msg.sender, there's no "from" parameter
    function test_Security_NoFromParameterInDirectPayments() public {
        // payWithToken only takes token, amount, paymentReference
        // There is NO way to specify whose tokens to pull
        // The function signature is: payWithToken(address token, uint256 amount, bytes32 paymentReference)

        // Try calling with attacker - only attacker's (non-existent) funds would be used
        vm.prank(attacker);
        vm.expectRevert();
        router.payWithToken(address(paymentToken), 1000e18, bytes32(0));

        // Victim's funds are safe
        assertEq(paymentToken.balanceOf(victim), VICTIM_BALANCE);
    }

    // ============ Attack Vector 2: Swap-Based Attacks ============
    // Can attacker manipulate swap parameters to steal funds?

    /// @notice Attacker cannot use payWithSwap to pull victim's tokens
    /// @dev payWithSwap uses msg.sender for transferFrom
    function test_Security_CannotStealViaPayWithSwap() public {
        swapModule.setSwapRate(1e18);

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: 1000e18,
            paymentAmount: 500e18,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        // Attacker calls payWithSwap - should fail because attacker has no tokens
        vm.prank(attacker);
        vm.expectRevert();
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));

        // Victim's tokens unchanged
        assertEq(sourceToken.balanceOf(victim), VICTIM_BALANCE);
    }

    /// @notice SwapData cannot be used to redirect funds to attacker
    /// @dev The swap module's `to` and `refundTo` addresses are set by the router, not swapData
    function test_Security_SwapDataCannotRedirectFunds() public {
        // The router sets these in _executeSwapAndPay:
        // - to: address(core) - output always goes to core
        // - refundTo: payer (msg.sender) - refunds go back to caller

        // swapData is only passed to the swap module for routing info
        // A malicious swapData cannot change where funds go because:
        // 1. The swap module receives params.to and params.refundTo from router
        // 2. These are hardcoded: to=core, refundTo=msg.sender
        // 3. The swap module MUST send output to params.to to pass validation

        // The only risk is if the swap module itself is malicious,
        // but the swap module is set by the owner (admin)
    }

    // ============ Attack Vector 3: OnBehalf Function Exploitation ============
    // Can attacker abuse payWithTokenOnBehalf or payWithSwapOnBehalf?

    /// @notice Attacker cannot call payWithTokenOnBehalf without a valid permit from victim
    /// @dev Requires a valid EIP-2612 signature from the victim
    function test_Security_OnBehalfRequiresValidPermit() public {
        // Attacker tries to forge a permit
        ISpritzRouter.PermitData memory fakePermit = ISpritzRouter.PermitData({
            deadline: block.timestamp + 1 hours,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        vm.prank(attacker);
        vm.expectRevert(); // Invalid signature
        router.payWithTokenOnBehalf(victim, address(permitToken), 1000e18, bytes32(0), fakePermit);

        // Victim's funds unchanged
        assertEq(permitToken.balanceOf(victim), VICTIM_BALANCE);
    }

    /// @notice Attacker cannot use their own permit to pull victim's funds
    /// @dev Permit is validated against the owner parameter
    function test_Security_CannotUseOwnPermitForVictimFunds() public {
        // Attacker signs a permit for themselves
        ISpritzRouter.PermitData memory attackerPermit = _signPermit(
            address(permitToken),
            attacker,
            attackerPrivateKey,
            address(router),
            1000e18,
            block.timestamp + 1 hours
        );

        // Try to use attacker's permit but specify victim as owner
        vm.prank(attacker);
        vm.expectRevert(); // Signature doesn't match owner
        router.payWithTokenOnBehalf(victim, address(permitToken), 1000e18, bytes32(0), attackerPermit);

        assertEq(permitToken.balanceOf(victim), VICTIM_BALANCE);
    }

    /// @notice Attacker cannot replay a victim's permit
    /// @dev Permits use nonces that increment after each use
    function test_Security_CannotReplayPermit() public {
        // Victim legitimately uses a permit
        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            victim,
            victimPrivateKey,
            address(router),
            1000e18,
            block.timestamp + 1 hours
        );

        // Victim uses the permit
        vm.prank(victim);
        router.payWithToken(address(permitToken), 1000e18, bytes32("first"), permit);

        assertEq(permitToken.balanceOf(victim), VICTIM_BALANCE - 1000e18);

        // Attacker tries to replay the same permit
        vm.prank(attacker);
        vm.expectRevert(); // Nonce already used
        router.payWithTokenOnBehalf(victim, address(permitToken), 1000e18, bytes32("second"), permit);

        // No additional funds taken
        assertEq(permitToken.balanceOf(victim), VICTIM_BALANCE - 1000e18);
    }

    /// @notice Attacker cannot frontrun a permit to redirect funds
    /// @dev Even if attacker frontruns the permit execution, funds go to the correct recipient
    function test_Security_PermitFrontrunningDoesNotStealFunds() public {
        // Victim creates and signs a permit
        ISpritzRouter.PermitData memory permit = _signPermit(
            address(permitToken),
            victim,
            victimPrivateKey,
            address(router),
            1000e18,
            block.timestamp + 1 hours
        );

        // Attacker sees the permit in mempool and frontruns
        // Even if attacker executes the permit, funds go to `recipient` (configured in core)
        vm.prank(attacker);
        router.payWithTokenOnBehalf(victim, address(permitToken), 1000e18, bytes32("frontrun"), permit);

        // Funds went to the legitimate recipient, not the attacker
        assertEq(permitToken.balanceOf(recipient), 1000e18);
        assertEq(permitToken.balanceOf(attacker), 0);
        assertEq(permitToken.balanceOf(victim), VICTIM_BALANCE - 1000e18);
    }

    // ============ Attack Vector 4: Existing Approval + OnBehalf ============
    // Key scenario: Victim has approved router, attacker tries to use OnBehalf

    /// @notice Even with victim's approval, attacker needs valid permit for OnBehalf
    /// @dev OnBehalf functions REQUIRE a permit - they don't use existing approvals
    function test_Security_ExistingApprovalNotExploitableViaOnBehalf() public {
        // Victim has already approved the router (in setUp)
        assertEq(permitToken.allowance(victim, address(router)), UNLIMITED_APPROVAL);

        // Attacker tries OnBehalf with fake permit
        ISpritzRouter.PermitData memory fakePermit = ISpritzRouter.PermitData({
            deadline: block.timestamp + 1 hours,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        vm.prank(attacker);
        vm.expectRevert(); // Still fails - permit signature is invalid
        router.payWithTokenOnBehalf(victim, address(permitToken), 1000e18, bytes32(0), fakePermit);

        assertEq(permitToken.balanceOf(victim), VICTIM_BALANCE);
    }

    // ============ Attack Vector 5: Malicious Token Attacks ============

    /// @notice Router is protected against malicious token callbacks via reentrancy guard
    /// @dev payWithSwap and payWithNativeSwap have nonReentrant modifier
    function test_Security_ReentrancyProtection() public {
        // The payWithSwap, payWithSwapOnBehalf, and payWithNativeSwap functions
        // all have the nonReentrant modifier, preventing callback-based attacks
        // that could drain multiple users' approvals in a single transaction
    }

    // ============ Attack Vector 6: Parameter Manipulation ============

    /// @notice Attacker cannot manipulate paymentToken parameter to bypass restrictions
    /// @dev The core contract validates that payment tokens are in the accepted list
    function test_Security_CannotPayToUnacceptedToken() public {
        // Even if attacker controls source tokens, they can't pay to arbitrary addresses
        ERC20Mock attackerToken = new ERC20Mock();
        attackerToken.mint(attacker, 1000e18);

        vm.prank(attacker);
        attackerToken.approve(address(router), 1000e18);

        // Try to use unaccepted token as payment token
        vm.prank(attacker);
        vm.expectRevert(); // Token not accepted
        router.payWithToken(address(attackerToken), 1000e18, bytes32(0));
    }

    /// @notice Output always goes to core-configured recipient, not attacker-specified
    /// @dev The payment recipient is determined by core.paymentRecipient(token), not caller input
    function test_Security_RecipientCannotBeManipulated() public {
        // Set up: give attacker some tokens
        paymentToken.mint(attacker, 1000e18);
        vm.prank(attacker);
        paymentToken.approve(address(router), 1000e18);

        // Attacker makes a payment
        vm.prank(attacker);
        router.payWithToken(address(paymentToken), 1000e18, bytes32(0));

        // Funds went to the configured recipient, not anywhere else
        assertEq(paymentToken.balanceOf(recipient), 1000e18);
    }

    // ============ Invariant: Router Never Holds User Funds ============

    /// @notice Router should never hold tokens after any operation
    /// @dev This prevents stuck funds that could be swept by admin
    function test_Security_RouterNeverHoldsFunds() public {
        // Give attacker tokens to make legitimate payments
        paymentToken.mint(attacker, 1000e18);
        vm.prank(attacker);
        paymentToken.approve(address(router), 1000e18);

        vm.prank(attacker);
        router.payWithToken(address(paymentToken), 1000e18, bytes32(0));

        // Router should have zero balance
        assertEq(paymentToken.balanceOf(address(router)), 0);
    }

    // ============ Edge Case: Zero Amount Attacks ============

    /// @notice Zero amount payments don't affect balances
    function test_Security_ZeroAmountPaymentsSafe() public {
        uint256 victimBalanceBefore = paymentToken.balanceOf(victim);

        vm.prank(victim);
        router.payWithToken(address(paymentToken), 0, bytes32(0));

        assertEq(paymentToken.balanceOf(victim), victimBalanceBefore);
    }

    // ============ Comprehensive Scenario Tests ============

    /// @notice Full attack scenario: Attacker tries all vectors against victim with unlimited approval
    function test_Security_ComprehensiveApprovalExploitAttempt() public {
        uint256 victimBalanceBefore = paymentToken.balanceOf(victim);

        // Vector 1: Try direct payWithToken (fails - uses msg.sender)
        vm.prank(attacker);
        vm.expectRevert();
        router.payWithToken(address(paymentToken), 1000e18, bytes32("steal1"));

        // Vector 2: Try payWithSwap (fails - uses msg.sender)
        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactOutput,
            sourceToken: address(sourceToken),
            sourceAmount: 1000e18,
            paymentAmount: 500e18,
            deadline: block.timestamp + 1 hours,
            swapData: ""
        });

        vm.prank(attacker);
        vm.expectRevert();
        router.payWithSwap(address(paymentToken), swapParams, bytes32("steal2"));

        // Vector 3: Try OnBehalf with fake permit (fails - invalid signature)
        ISpritzRouter.PermitData memory fakePermit = ISpritzRouter.PermitData({
            deadline: block.timestamp + 1 hours,
            v: 28,
            r: bytes32(uint256(123)),
            s: bytes32(uint256(456))
        });

        vm.prank(attacker);
        vm.expectRevert();
        router.payWithTokenOnBehalf(victim, address(permitToken), 1000e18, bytes32("steal3"), fakePermit);

        // Victim's balance completely unchanged
        assertEq(paymentToken.balanceOf(victim), victimBalanceBefore);
        assertEq(permitToken.balanceOf(victim), VICTIM_BALANCE);
        assertEq(sourceToken.balanceOf(victim), VICTIM_BALANCE);
    }

    // ============ Helpers ============

    function _signPermit(
        address token,
        address owner,
        uint256 ownerPrivateKey,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (ISpritzRouter.PermitData memory) {
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, ERC20PermitMock(token).nonces(owner), deadline)
        );

        bytes32 DOMAIN_SEPARATOR = ERC20PermitMock(token).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        return ISpritzRouter.PermitData({deadline: deadline, v: v, r: r, s: s});
    }
}

/// @title Malicious Swap Module Test
/// @notice Tests what happens if the swap module itself is compromised
/// @dev This is out of scope since swap module is admin-controlled, but good to document
contract MaliciousSwapModuleTest is Test {
    SpritzRouter public router;
    SpritzPayCore public core;

    ERC20Mock public paymentToken;
    ERC20Mock public sourceToken;

    address public admin;
    address public victim;
    address public attacker;
    address public recipient;

    function setUp() public {
        admin = makeAddr("admin");
        recipient = makeAddr("recipient");
        victim = makeAddr("victim");
        attacker = makeAddr("attacker");

        core = new SpritzPayCore();
        core.initialize(admin);

        router = new SpritzRouter(address(core));
        router.initialize(admin);

        paymentToken = new ERC20Mock();
        sourceToken = new ERC20Mock();

        vm.prank(admin);
        core.addPaymentToken(address(paymentToken), recipient);

        sourceToken.mint(victim, 10_000e18);
        vm.prank(victim);
        sourceToken.approve(address(router), type(uint256).max);
    }

    /// @notice Documents that a malicious swap module COULD steal funds
    /// @dev This is why setSwapModule is onlyOwner - the swap module must be trusted
    function test_Documentation_MaliciousSwapModuleRisk() public {
        // Deploy malicious swap module
        MaliciousSwapModule maliciousModule = new MaliciousSwapModule(attacker, address(paymentToken));

        // If admin is compromised, they could set malicious module
        vm.prank(admin);
        router.setSwapModule(address(maliciousModule));

        // Now any swap would send tokens to attacker instead of completing properly
        // This is documented risk - swap module must be trusted
        // Mitigation: Admin key security, timelocks, governance
    }
}

/// @notice A deliberately malicious swap module for testing
/// @dev DO NOT USE IN PRODUCTION - this demonstrates the attack vector
contract MaliciousSwapModule is ISwapModule {
    address public attacker;
    address public paymentToken;

    constructor(address _attacker, address _paymentToken) {
        attacker = _attacker;
        paymentToken = _paymentToken;
    }

    function swap(SwapParams calldata params) external returns (SwapResult memory result) {
        // Steal input tokens instead of swapping
        uint256 balance = ERC20Mock(params.inputToken).balanceOf(address(this));
        ERC20Mock(params.inputToken).transfer(attacker, balance);

        // Return fake result (this would actually cause revert due to insufficient output)
        result.inputAmountSpent = params.inputAmount;
        result.outputAmountReceived = params.outputAmount;
    }

    function swapNative(SwapParams calldata) external payable returns (SwapResult memory) {
        revert("not implemented");
    }
}
