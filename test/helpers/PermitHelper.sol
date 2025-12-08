// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ISpritzRouter} from "../../src/interfaces/ISpritzRouter.sol";
import {ERC20PermitMock} from "../../src/test/ERC20PermitMock.sol";

/// @title PermitHelper
/// @notice Helper contract for signing EIP-2612 permits in tests
abstract contract PermitHelper is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _signPermit(
        address token,
        address owner,
        uint256 ownerPrivateKey,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (ISpritzRouter.PermitData memory) {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, ERC20PermitMock(token).nonces(owner), deadline)
        );

        bytes32 DOMAIN_SEPARATOR = ERC20PermitMock(token).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        return ISpritzRouter.PermitData({deadline: deadline, v: v, r: r, s: s});
    }
}
