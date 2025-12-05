// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SpritzPayCore} from "../src/SpritzPayCore.sol";
import {SpritzRouter} from "../src/SpritzRouter.sol";

/// @notice CreateX factory interface (deployed at same address on all chains)
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

/// @title DeploySpritz
/// @notice Deploys SpritzPayCore and SpritzRouter using CreateX for deterministic addresses
/// @dev Uses FROZEN bytecode from deployments/<ContractName>/ to ensure identical deployments across chains.
///
/// Usage:
///   node scripts/deploy.js <chain>           Deploy with 1Password
///   node scripts/deploy.js <chain> --dry-run Simulate deployment
contract DeploySpritz is Script {
    // CreateX is deployed at the same address on all chains
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    // Expected bytecode hashes (keccak256 of initcode files, from metadata.json)
    bytes32 public constant CORE_INITCODE_HASH = 0x22171b08d4d10c8ca3cd88f56fefe85f1e3d1fe6b84067ba02dea10e952dd247;
    bytes32 public constant ROUTER_INITCODE_HASH = 0x75631bbfbb898fc857e49561f729ad76420eeba363e0879ea074dcd235c67321;

    // Config from environment
    address public admin;
    bytes32 public coreSalt;
    bytes32 public routerSalt;

    function setUp() public {
        admin = vm.envOr("ADMIN_ADDRESS", address(0));
        require(admin != address(0), "Set ADMIN_ADDRESS env var");

        coreSalt = vm.envBytes32("CORE_SALT");
        routerSalt = vm.envBytes32("ROUTER_SALT");
    }

    function run() public {
        // Load frozen bytecode from deployment packages
        bytes memory coreInitCode = _loadBytecode("deployments/SpritzPayCore/artifacts/SpritzPayCore.initcode");
        bytes memory routerBaseInitCode = _loadBytecode("deployments/SpritzRouter/artifacts/SpritzRouter.initcode");

        // Verify bytecode matches expected hashes
        require(
            keccak256(coreInitCode) == CORE_INITCODE_HASH,
            "Core bytecode hash mismatch! Deployment package may be corrupted."
        );
        require(
            keccak256(routerBaseInitCode) == ROUTER_INITCODE_HASH,
            "Router bytecode hash mismatch! Deployment package may be corrupted."
        );

        // Verify deployer matches salt
        address expectedDeployer = address(bytes20(coreSalt));
        require(msg.sender == expectedDeployer, "Deployer doesn't match salt");

        // Compute guarded salts (CreateX applies _guard internally during deployment)
        // For salt format [deployer (20 bytes)][0x00][entropy], _guard uses _efficientHash:
        // guardedSalt = keccak256(bytes32(uint256(uint160(msg.sender))) ++ salt)
        bytes32 guardedCoreSalt = _efficientHash(bytes32(uint256(uint160(msg.sender))), coreSalt);
        bytes32 guardedRouterSalt = _efficientHash(bytes32(uint256(uint160(msg.sender))), routerSalt);

        // Preview addresses using guarded salts
        address expectedCore = CREATEX.computeCreate3Address(guardedCoreSalt, address(CREATEX));
        address expectedRouter = CREATEX.computeCreate3Address(guardedRouterSalt, address(CREATEX));

        console.log("=== Deployment Preview ===");
        console.log("Deployer:", msg.sender);
        console.log("Admin:", admin);
        console.log("Expected Core address:", expectedCore);
        console.log("Expected Router address:", expectedRouter);
        console.log("");
        console.log("Using FROZEN bytecode from deployments/v1/");
        console.log("");

        // No ETH needed for constructor or init calls
        ICreateX.Values memory noValue = ICreateX.Values({constructorAmount: 0, initCallAmount: 0});

        vm.startBroadcast();

        // 1. Deploy and initialize SpritzPayCore atomically
        address core = CREATEX.deployCreate3AndInit(
            coreSalt,
            coreInitCode,
            abi.encodeCall(SpritzPayCore.initialize, (admin)),
            noValue
        );
        console.log("SpritzPayCore deployed and initialized at:", core);
        require(core == expectedCore, "Core address mismatch!");

        // 2. Deploy and initialize SpritzRouter atomically
        // Append core address to frozen bytecode (constructor arg)
        bytes memory routerInitCode = abi.encodePacked(routerBaseInitCode, abi.encode(core));
        address router = CREATEX.deployCreate3AndInit(
            routerSalt,
            routerInitCode,
            abi.encodeCall(SpritzRouter.initialize, (admin)),
            noValue
        );
        console.log("SpritzRouter deployed and initialized at:", router);
        require(router == expectedRouter, "Router address mismatch!");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Core:", core);
        console.log("Router:", router);
        console.log("");
        console.log("Next steps:");
        console.log("1. Verify contracts on block explorer");
        console.log("2. Set up payment tokens: core.addPaymentToken(token, recipient)");
        console.log("3. Set swap module: router.setSwapModule(swapModule)");
    }

    /// @dev Replicates CreateX's _efficientHash for computing guarded salts
    function _efficientHash(bytes32 a, bytes32 b) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }

    /// @dev Loads bytecode from a file, stripping the 0x prefix if present
    function _loadBytecode(string memory path) internal view returns (bytes memory) {
        string memory hexString = vm.readFile(path);

        // Remove trailing newline if present
        bytes memory hexBytes = bytes(hexString);
        uint256 len = hexBytes.length;
        if (len > 0 && hexBytes[len - 1] == 0x0a) {
            len--;
        }
        if (len > 0 && hexBytes[len - 1] == 0x0d) {
            len--;
        }

        // Check for 0x prefix and skip it
        uint256 start = 0;
        if (len >= 2 && hexBytes[0] == "0" && hexBytes[1] == "x") {
            start = 2;
        }

        // Convert hex string to bytes
        uint256 bytesLen = (len - start) / 2;
        bytes memory result = new bytes(bytesLen);

        for (uint256 i = 0; i < bytesLen; i++) {
            result[i] = bytes1(_fromHexChar(uint8(hexBytes[start + i * 2])) * 16 + _fromHexChar(uint8(hexBytes[start + i * 2 + 1])));
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

/// @title DeploySpritzPreview
/// @notice Preview deployment addresses without actually deploying
contract DeploySpritzPreview is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    bytes32 public constant CORE_SALT = 0xbadfaceb351045374d7fd1d3915e62501ba9916c009a4573d5a53c4f001a7dda;
    bytes32 public constant ROUTER_SALT = 0xbadfaceb351045374d7fd1d3915e62501ba9916c009a4573d5a53c4f001a7ddb;

    function run() public view {
        address deployer = msg.sender;

        console.log("=== Address Preview ===");
        console.log("Deployer:", deployer);
        console.log("");
        console.log("With current deployer, contracts will be at:");
        console.log("  Core:", CREATEX.computeCreate3Address(CORE_SALT, deployer));
        console.log("  Router:", CREATEX.computeCreate3Address(ROUTER_SALT, deployer));
        console.log("");
        console.log("NOTE: Same deployer + same salt = same address on ALL chains");
    }
}

/// @title DeploySpritzForkTest
/// @notice Test deployment on a fork without needing a private key
/// @dev Uses vm.prank to simulate deployment from a specific address
///
/// Usage:
///   DEPLOYER=0xYourDeployer ADMIN_ADDRESS=0xYourAdmin forge script script/Deploy.s.sol:DeploySpritzForkTest --rpc-url $RPC_URL
contract DeploySpritzForkTest is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    bytes32 public constant CORE_INITCODE_HASH = 0x22171b08d4d10c8ca3cd88f56fefe85f1e3d1fe6b84067ba02dea10e952dd247;
    bytes32 public constant ROUTER_INITCODE_HASH = 0x75631bbfbb898fc857e49561f729ad76420eeba363e0879ea074dcd235c67321;

    function run() public {
        // Read salts from environment (required)
        bytes32 coreSalt = vm.envBytes32("CORE_SALT");
        bytes32 routerSalt = vm.envBytes32("ROUTER_SALT");

        // Deployer is derived from salt (first 20 bytes)
        address deployer = address(bytes20(coreSalt));
        address admin = vm.envOr("ADMIN_ADDRESS", address(0xAD1));

        // Load frozen bytecode
        bytes memory coreInitCode = _loadBytecode("deployments/SpritzPayCore/artifacts/SpritzPayCore.initcode");
        bytes memory routerBaseInitCode = _loadBytecode("deployments/SpritzRouter/artifacts/SpritzRouter.initcode");

        // Verify bytecode hashes
        require(keccak256(coreInitCode) == CORE_INITCODE_HASH, "Core bytecode hash mismatch!");
        require(keccak256(routerBaseInitCode) == ROUTER_INITCODE_HASH, "Router bytecode hash mismatch!");

        console.log("=== Fork Test Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Admin:", admin);
        console.log("");

        ICreateX.Values memory noValue = ICreateX.Values({constructorAmount: 0, initCallAmount: 0});

        // Fund the deployer on the fork
        vm.deal(deployer, 1 ether);

        // Deploy Core
        vm.prank(deployer);
        address core = CREATEX.deployCreate3AndInit(
            coreSalt,
            coreInitCode,
            abi.encodeCall(SpritzPayCore.initialize, (admin)),
            noValue
        );
        console.log("Core deployed at:", core);

        // Deploy Router
        bytes memory routerInitCode = abi.encodePacked(routerBaseInitCode, abi.encode(core));
        vm.prank(deployer);
        address router = CREATEX.deployCreate3AndInit(
            routerSalt,
            routerInitCode,
            abi.encodeCall(SpritzRouter.initialize, (admin)),
            noValue
        );
        console.log("Router deployed at:", router);

        // Verify deployment
        console.log("");
        console.log("=== Verification ===");
        console.log("Core owner:", SpritzPayCore(core).owner());
        console.log("Router owner:", SpritzRouter(payable(router)).owner());
        console.log("Router core:", address(SpritzRouter(payable(router)).core()));

        require(SpritzPayCore(core).owner() == admin, "Core owner mismatch!");
        require(SpritzRouter(payable(router)).owner() == admin, "Router owner mismatch!");
        require(address(SpritzRouter(payable(router)).core()) == core, "Router core mismatch!");

        console.log("");
        console.log("=== Fork Test PASSED ===");
        console.log("");
        console.log("These addresses will be the SAME on all chains:");
        console.log("  Core:", core);
        console.log("  Router:", router);
    }

    function _loadBytecode(string memory path) internal view returns (bytes memory) {
        string memory hexString = vm.readFile(path);
        bytes memory hexBytes = bytes(hexString);
        uint256 len = hexBytes.length;
        if (len > 0 && hexBytes[len - 1] == 0x0a) len--;
        if (len > 0 && hexBytes[len - 1] == 0x0d) len--;

        uint256 start = 0;
        if (len >= 2 && hexBytes[0] == "0" && hexBytes[1] == "x") start = 2;

        uint256 bytesLen = (len - start) / 2;
        bytes memory result = new bytes(bytesLen);
        for (uint256 i = 0; i < bytesLen; i++) {
            result[i] = bytes1(_fromHexChar(uint8(hexBytes[start + i * 2])) * 16 + _fromHexChar(uint8(hexBytes[start + i * 2 + 1])));
        }
        return result;
    }

    function _fromHexChar(uint8 c) internal pure returns (uint8) {
        if (c >= uint8(bytes1("0")) && c <= uint8(bytes1("9"))) return c - uint8(bytes1("0"));
        if (c >= uint8(bytes1("a")) && c <= uint8(bytes1("f"))) return 10 + c - uint8(bytes1("a"));
        if (c >= uint8(bytes1("A")) && c <= uint8(bytes1("F"))) return 10 + c - uint8(bytes1("A"));
        revert("Invalid hex character");
    }
}
