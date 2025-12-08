// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IParaSwapAugustus
/// @notice Interface for the ParaSwap Augustus router
interface IParaSwapAugustus {
    function getTokenTransferProxy() external view returns (address);
}

/// @title IParaSwapAugustusRegistry
/// @notice Interface for the ParaSwap Augustus registry
interface IParaSwapAugustusRegistry {
    function isValidAugustus(address augustus) external view returns (bool);
}
