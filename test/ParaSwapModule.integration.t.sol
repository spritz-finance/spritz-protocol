// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ParaSwapModule} from "../src/modules/ParaSwapModule.sol";
import {SwapModuleBase} from "../src/modules/SwapModuleBase.sol";
import {ISpritzRouter} from "../src/interfaces/ISpritzRouter.sol";
import {ISwapModule} from "../src/interfaces/ISwapModule.sol";
import {MockDEXExchange, MockParaSwapRegistry, MockParaSwapAugustus} from "./mocks/MockDEX.sol";
import {SwapModuleIntegrationBase} from "./helpers/SwapModuleIntegrationBase.sol";

/// @title ParaSwapModule Integration Tests
/// @notice Tests the full flow: User -> Router -> ParaSwapModule -> Core
contract ParaSwapModuleIntegrationTest is SwapModuleIntegrationBase {
    ParaSwapModule public paraSwapModule;
    MockParaSwapRegistry public registry;
    MockParaSwapAugustus public augustus;

    function setUp() public {
        _baseSetUp();

        registry = new MockParaSwapRegistry();
        augustus = new MockParaSwapAugustus();

        registry.setValidAugustus(address(augustus), true);

        paraSwapModule = new ParaSwapModule(address(registry), address(weth));

        vm.prank(admin);
        router.setSwapModule(address(paraSwapModule));

        vm.label(address(paraSwapModule), "ParaSwapModule");
        vm.label(address(registry), "Registry");
        vm.label(address(augustus), "Augustus");
    }

    function _swapModule() internal view override returns (address) {
        return address(paraSwapModule);
    }

    function _exchange() internal view override returns (MockDEXExchange) {
        return augustus;
    }

    function _encodeSwapData(bytes memory callData) internal view override returns (bytes memory) {
        return abi.encode(callData, address(augustus));
    }

    function _insufficientOutputSelector() internal pure override returns (bytes4) {
        return SwapModuleBase.InsufficientOutput.selector;
    }

    function _insufficientInputSelector() internal pure override returns (bytes4) {
        return SwapModuleBase.InsufficientInput.selector;
    }

    // ============ ParaSwap-Specific Tests ============

    function test_RevertWhen_InvalidAugustus() public {
        sourceToken.mint(user, 1000e18);
        vm.prank(user);
        sourceToken.approve(address(router), 1000e18);

        // Use a non-registered augustus
        address fakeAugustus = makeAddr("fakeAugustus");
        bytes memory swapData = abi.encode(bytes(""), fakeAugustus);

        ISpritzRouter.SwapPaymentParams memory swapParams = ISpritzRouter.SwapPaymentParams({
            swapType: ISwapModule.SwapType.ExactInput,
            sourceToken: address(sourceToken),
            sourceAmount: 1000e18,
            paymentAmount: 0,
            deadline: block.timestamp + 1 hours,
            swapData: swapData
        });

        vm.prank(user);
        vm.expectRevert(SwapModuleBase.InvalidSwapTarget.selector);
        router.payWithSwap(address(paymentToken), swapParams, bytes32(0));
    }

    function test_RegistryValidation() public {
        // Verify the registry is being used
        assertTrue(registry.isValidAugustus(address(augustus)));
        assertFalse(registry.isValidAugustus(address(0)));
        assertFalse(registry.isValidAugustus(makeAddr("random")));
    }
}
