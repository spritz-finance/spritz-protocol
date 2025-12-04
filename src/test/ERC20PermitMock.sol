// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract ERC20PermitMock is ERC20, ERC20Permit {
    constructor() ERC20("Mock Permit Token", "MPT") ERC20Permit("Mock Permit Token") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}
