// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {OpenOceanModule} from "../src/modules/OpenOceanModule.sol";
import {SwapModuleBase} from "../src/modules/SwapModuleBase.sol";
import {MockDEXExchange} from "./mocks/MockDEX.sol";
import {SwapModuleIntegrationBase} from "./helpers/SwapModuleIntegrationBase.sol";

/// @title OpenOceanModule Integration Tests
/// @notice Tests the full flow: User -> Router -> OpenOceanModule -> Core
contract OpenOceanModuleIntegrationTest is SwapModuleIntegrationBase {
    OpenOceanModule public openOceanModule;
    MockDEXExchange public exchange;

    function setUp() public {
        _baseSetUp();

        exchange = new MockDEXExchange();
        openOceanModule = new OpenOceanModule(address(exchange), address(weth));

        vm.prank(admin);
        router.setSwapModule(address(openOceanModule));

        vm.label(address(openOceanModule), "OpenOceanModule");
        vm.label(address(exchange), "Exchange");
    }

    function _swapModule() internal view override returns (address) {
        return address(openOceanModule);
    }

    function _exchange() internal view override returns (MockDEXExchange) {
        return exchange;
    }

    function _encodeSwapData(bytes memory callData) internal view override returns (bytes memory) {
        return abi.encode(callData, address(exchange));
    }

    function _insufficientOutputSelector() internal pure override returns (bytes4) {
        return SwapModuleBase.InsufficientOutput.selector;
    }

    function _insufficientInputSelector() internal pure override returns (bytes4) {
        return SwapModuleBase.InsufficientInput.selector;
    }

    // ============ OpenOcean-Specific Tests ============

    function test_RevertWhen_InvalidExchangeTarget() public {
        sourceToken.mint(user, 1000e18);
        vm.prank(user);
        sourceToken.approve(address(router), 1000e18);

        // Use wrong exchange address in swapData
        bytes memory swapData = abi.encode(bytes(""), address(0xdead));

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
}

import {ISpritzRouter} from "../src/interfaces/ISpritzRouter.sol";
import {ISwapModule} from "../src/interfaces/ISwapModule.sol";
