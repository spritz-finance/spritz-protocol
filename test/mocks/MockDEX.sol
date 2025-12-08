// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20Mock} from "../../src/test/ERC20Mock.sol";
import {IParaSwapAugustus, IParaSwapAugustusRegistry} from "../../src/interfaces/IParaSwap.sol";

/// @title MockDEXExchange
/// @notice Generic mock DEX exchange for testing swap modules
/// @dev Simulates both ExactInput and ExactOutput swaps with configurable rates
contract MockDEXExchange {
    uint256 public swapRate = 1e18;
    bool public shouldFail;
    uint256 public inputOverride;
    uint256 public outputOverride;

    function setSwapRate(uint256 rate) external {
        swapRate = rate;
    }

    function setShouldFail(bool fail) external {
        shouldFail = fail;
    }

    function setInputOverride(uint256 amount) external {
        inputOverride = amount;
    }

    function setOutputOverride(uint256 amount) external {
        outputOverride = amount;
    }

    function swap(address inputToken, address outputToken, uint256 inputAmount) external returns (uint256) {
        require(!shouldFail, "Swap failed");

        ERC20Mock(inputToken).transferFrom(msg.sender, address(this), inputAmount);

        uint256 outputAmount = (inputAmount * swapRate) / 1e18;
        ERC20Mock(outputToken).mint(msg.sender, outputAmount);

        return outputAmount;
    }

    function swapExactOutput(address inputToken, address outputToken, uint256 outputAmount)
        external
        returns (uint256)
    {
        require(!shouldFail, "Swap failed");

        uint256 inputRequired = inputOverride > 0 ? inputOverride : (outputAmount * 1e18) / swapRate;
        ERC20Mock(inputToken).transferFrom(msg.sender, address(this), inputRequired);

        uint256 actualOutput = outputOverride > 0 ? outputOverride : outputAmount;
        ERC20Mock(outputToken).mint(msg.sender, actualOutput);

        return inputRequired;
    }
}

/// @title MockParaSwapRegistry
/// @notice Mock ParaSwap Augustus registry for testing
contract MockParaSwapRegistry is IParaSwapAugustusRegistry {
    mapping(address => bool) public validAugustus;

    function setValidAugustus(address augustus, bool valid) external {
        validAugustus[augustus] = valid;
    }

    function isValidAugustus(address augustus) external view override returns (bool) {
        return validAugustus[augustus];
    }
}

/// @title MockParaSwapAugustus
/// @notice Mock ParaSwap Augustus router that extends MockDEXExchange
contract MockParaSwapAugustus is MockDEXExchange, IParaSwapAugustus {
    address public tokenTransferProxy;

    constructor() {
        tokenTransferProxy = address(this);
    }

    function getTokenTransferProxy() external view override returns (address) {
        return tokenTransferProxy;
    }
}
