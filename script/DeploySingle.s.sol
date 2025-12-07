// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

interface ICreateX {
    struct Values {
        uint256 constructorAmount;
        uint256 initCallAmount;
    }

    function deployCreate3AndInit(
        bytes32 salt,
        bytes memory initCode,
        bytes memory data,
        Values memory values
    ) external payable returns (address);

    function computeCreate3Address(bytes32 salt, address deployer) external view returns (address);
}

interface IInitializable {
    function initialize(address admin) external;
}

/// @title DeploySingle
/// @notice Deploys a single contract using CreateX with frozen bytecode
/// @dev Environment variables:
///      - ADMIN_ADDRESS: Admin address for initialize()
///      - CONTRACT_NAME: Name of the contract (e.g., "SpritzPayCore")
///      - CONTRACT_SALT: CREATE3 salt for deterministic address
///      - CONSTRUCTOR_ARGS: Comma-separated constructor args (addresses only)
contract DeploySingle is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    function run() public {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        string memory contractName = vm.envString("CONTRACT_NAME");
        bytes32 salt = vm.envBytes32("CONTRACT_SALT");
        string memory constructorArgsStr = vm.envOr("CONSTRUCTOR_ARGS", string(""));

        require(admin != address(0), "ADMIN_ADDRESS required");
        require(bytes(contractName).length > 0, "CONTRACT_NAME required");

        address expectedDeployer = address(bytes20(salt));
        require(msg.sender == expectedDeployer, "Deployer doesn't match salt");

        bytes memory baseInitcode = _loadFrozenBytecode(contractName);

        bytes memory initcode;
        if (bytes(constructorArgsStr).length > 0) {
            address[] memory args = _parseAddresses(constructorArgsStr);
            bytes memory encodedArgs = _encodeAddresses(args);
            initcode = abi.encodePacked(baseInitcode, encodedArgs);

            console.log("Constructor args:");
            for (uint256 i = 0; i < args.length; i++) {
                console.log("  [%d]: %s", i, args[i]);
            }
        } else {
            initcode = baseInitcode;
        }

        bytes32 guardedSalt = _efficientHash(bytes32(uint256(uint160(msg.sender))), salt);
        address expectedAddress = CREATEX.computeCreate3Address(guardedSalt, address(CREATEX));

        console.log("");
        console.log("=== Deploy Single Contract ===");
        console.log("Contract:", contractName);
        console.log("Deployer:", msg.sender);
        console.log("Admin:", admin);
        console.log("Expected address:", expectedAddress);
        console.log("");

        ICreateX.Values memory noValue = ICreateX.Values({constructorAmount: 0, initCallAmount: 0});

        vm.startBroadcast();

        address deployed = CREATEX.deployCreate3AndInit(
            salt,
            initcode,
            abi.encodeCall(IInitializable.initialize, (admin)),
            noValue
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Contract:", contractName);
        console.log("Address:", deployed);
        require(deployed == expectedAddress, "Address mismatch!");
    }

    function _loadFrozenBytecode(string memory contractName) internal view returns (bytes memory) {
        string memory path = string.concat("deployments/", contractName, "/artifacts/", contractName, ".initcode");
        string memory hexString = vm.readFile(path);
        return _hexToBytes(hexString);
    }

    function _parseAddresses(string memory input) internal pure returns (address[] memory) {
        if (bytes(input).length == 0) {
            return new address[](0);
        }

        uint256 count = 1;
        bytes memory inputBytes = bytes(input);
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == ",") count++;
        }

        address[] memory addresses = new address[](count);
        uint256 start = 0;
        uint256 idx = 0;

        for (uint256 i = 0; i <= inputBytes.length; i++) {
            if (i == inputBytes.length || inputBytes[i] == ",") {
                bytes memory segment = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    segment[j - start] = inputBytes[j];
                }
                addresses[idx] = _parseAddress(string(segment));
                idx++;
                start = i + 1;
            }
        }

        return addresses;
    }

    function _parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42, "Invalid address length");
        require(b[0] == "0" && b[1] == "x", "Missing 0x prefix");

        uint160 result = 0;
        for (uint256 i = 2; i < 42; i++) {
            result = result * 16 + uint160(_fromHexChar(uint8(b[i])));
        }
        return address(result);
    }

    function _encodeAddresses(address[] memory addresses) internal pure returns (bytes memory) {
        if (addresses.length == 0) return "";
        if (addresses.length == 1) return abi.encode(addresses[0]);
        if (addresses.length == 2) return abi.encode(addresses[0], addresses[1]);
        if (addresses.length == 3) return abi.encode(addresses[0], addresses[1], addresses[2]);
        if (addresses.length == 4) return abi.encode(addresses[0], addresses[1], addresses[2], addresses[3]);
        revert("Too many constructor args");
    }

    function _efficientHash(bytes32 a, bytes32 b) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }

    function _hexToBytes(string memory hexString) internal pure returns (bytes memory) {
        bytes memory hexBytes = bytes(hexString);
        uint256 len = hexBytes.length;

        if (len > 0 && hexBytes[len - 1] == 0x0a) len--;
        if (len > 0 && hexBytes[len - 1] == 0x0d) len--;

        uint256 start = 0;
        if (len >= 2 && hexBytes[0] == "0" && hexBytes[1] == "x") {
            start = 2;
        }

        uint256 bytesLen = (len - start) / 2;
        bytes memory result = new bytes(bytesLen);

        for (uint256 i = 0; i < bytesLen; i++) {
            result[i] = bytes1(
                _fromHexChar(uint8(hexBytes[start + i * 2])) * 16 + _fromHexChar(uint8(hexBytes[start + i * 2 + 1]))
            );
        }

        return result;
    }

    function _fromHexChar(uint8 c) internal pure returns (uint8) {
        if (c >= uint8(bytes1("0")) && c <= uint8(bytes1("9"))) {
            return c - uint8(bytes1("0"));
        }
        if (c >= uint8(bytes1("a")) && c <= uint8(bytes1("f"))) {
            return 10 + c - uint8(bytes1("a"));
        }
        if (c >= uint8(bytes1("A")) && c <= uint8(bytes1("F"))) {
            return 10 + c - uint8(bytes1("A"));
        }
        revert("Invalid hex character");
    }
}
