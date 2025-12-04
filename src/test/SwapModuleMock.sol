// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ISwapModule} from "../interfaces/ISwapModule.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

contract SwapModuleMock is ISwapModule {
    uint256 public swapRate = 1e18;
    uint256 public outputShortfall;

    function setSwapRate(uint256 rate) external {
        swapRate = rate;
    }

    function setOutputShortfall(uint256 shortfall) external {
        outputShortfall = shortfall;
    }

    function swap(SwapParams calldata params) external override returns (SwapResult memory result) {
        uint256 inputBalance = ERC20Mock(params.inputToken).balanceOf(address(this));

        if (params.swapType == SwapType.ExactOutput) {
            uint256 inputNeeded = (params.outputAmount * 1e18) / swapRate;
            if (inputNeeded > inputBalance) {
                inputNeeded = inputBalance;
            }

            uint256 actualOutput = params.outputAmount > outputShortfall
                ? params.outputAmount - outputShortfall
                : 0;
            ERC20Mock(params.outputToken).mint(params.to, actualOutput);

            uint256 refund = inputBalance - inputNeeded;
            if (refund > 0) {
                SafeTransferLib.safeTransfer(params.inputToken, params.refundTo, refund);
            }

            ERC20Mock(params.inputToken).burn(address(this), inputNeeded);

            result.inputAmountSpent = inputNeeded;
            result.outputAmountReceived = actualOutput;
        } else {
            uint256 outputAmount = (inputBalance * swapRate) / 1e18;

            ERC20Mock(params.outputToken).mint(params.to, outputAmount);
            ERC20Mock(params.inputToken).burn(address(this), inputBalance);

            result.inputAmountSpent = inputBalance;
            result.outputAmountReceived = outputAmount;
        }
    }

    function swapNative(SwapParams calldata params) external payable override returns (SwapResult memory result) {
        if (params.swapType == SwapType.ExactOutput) {
            uint256 inputNeeded = (params.outputAmount * 1e18) / swapRate;
            if (inputNeeded > msg.value) {
                inputNeeded = msg.value;
            }

            ERC20Mock(params.outputToken).mint(params.to, params.outputAmount);

            uint256 refund = msg.value - inputNeeded;
            if (refund > 0) {
                (bool success,) = params.refundTo.call{value: refund}("");
                require(success, "ETH refund failed");
            }

            result.inputAmountSpent = inputNeeded;
            result.outputAmountReceived = params.outputAmount;
        } else {
            uint256 outputAmount = (msg.value * swapRate) / 1e18;

            ERC20Mock(params.outputToken).mint(params.to, outputAmount);

            result.inputAmountSpent = msg.value;
            result.outputAmountReceived = outputAmount;
        }
    }
}
