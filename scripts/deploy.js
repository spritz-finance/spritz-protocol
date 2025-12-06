#!/usr/bin/env node

/**
 * Deploy Script - Deploys frozen contracts via CreateX with 1Password integration
 *
 * Usage:
 *   node scripts/deploy.js <chain>              Deploy to a chain
 *   node scripts/deploy.js <chain> --dry-run    Simulate without broadcasting
 *   node scripts/deploy.js --list               List available chains
 *
 * Setup:
 *   1. Install 1Password CLI: https://developer.1password.com/docs/cli/get-started
 *   2. Sign in: op signin
 *   3. Update DEPLOYER_KEY_REF below with your 1Password reference
 */

const { execSync, spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

// =============================================================================
// CONFIGURATION - Can be overridden with environment variables
// =============================================================================

// 1Password reference to your deployer private key
// Format: op://Vault/Item/Field
// Override: DEPLOYER_KEY_REF env var
const DEPLOYER_KEY_REF =
  process.env.DEPLOYER_KEY_REF || "op://Personal/spritz-deployer-1/pk";

// Salts for deterministic addresses (must match Deploy.s.sol)
// The first 20 bytes of each salt encode the required deployer address
// Override: CORE_SALT and ROUTER_SALT env vars
const CORE_SALT =
  process.env.CORE_SALT ||
  "0xbadfaceb351045374d7fd1d3915e62501ba9916c009a4573d5a53c4f001a7dda";
const ROUTER_SALT =
  process.env.ROUTER_SALT ||
  "0xbadfaceb351045374d7fd1d3915e62501ba9916c009a4573d5a53c4f001a7ddb";

const CONTRACT_ADMIN = "0x48C53571800Fe3Cf8fF5923be67AB002BDCC085F";

// Alchemy RPC key - Override: RPC_KEY env var
const RPC_KEY = process.env.RPC_KEY || "V7EZ7G37jH8n99lLwsTr7";

const DEPLOYMENTS_DIR = path.join(__dirname, "..", "deployments");

// Chain configurations
const CHAINS = {
  // Mainnets
  ethereum: {
    rpc: `https://eth-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://etherscan.io",
    chainId: 1,
  },
  base: {
    rpc: `https://base-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://basescan.org",
    chainId: 8453,
  },
  arbitrum: {
    rpc: `https://arb-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://arbiscan.io",
    chainId: 42161,
  },
  optimism: {
    rpc: `https://opt-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://optimistic.etherscan.io",
    chainId: 10,
  },
  polygon: {
    rpc: `https://polygon-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://polygonscan.com",
    chainId: 137,
  },
  avalanche: {
    rpc: `https://avax-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://snowtrace.io",
    chainId: 43114,
  },
  bsc: {
    rpc: `https://bnb-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://bscscan.com",
    chainId: 56,
  },
  hyperevm: {
    rpc: `https://hyperliquid-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://explorer.hyperliquid.xyz",
    chainId: 999,
  },
  monad: {
    rpc: `https://monad-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://explorer.monad.xyz",
    chainId: 10143,
  },
  sonic: {
    rpc: `https://sonic-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://sonicscan.org",
    chainId: 146,
  },
  unichain: {
    rpc: `https://unichain-mainnet.g.alchemy.com/v2/${RPC_KEY}`,
    admin: CONTRACT_ADMIN,
    explorer: "https://uniscan.xyz",
    chainId: 130,
  },

  // Testnets
  sepolia: {
    rpc: "https://rpc.sepolia.org",
    admin: CONTRACT_ADMIN,
    explorer: "https://sepolia.etherscan.io",
    chainId: 11155111,
    testnet: true,
  },
  "base-sepolia": {
    rpc: "https://sepolia.base.org",
    admin: CONTRACT_ADMIN,
    explorer: "https://sepolia.basescan.org",
    chainId: 84532,
    testnet: true,
  },
};

// =============================================================================
// Script
// =============================================================================

const colors = {
  reset: "\x1b[0m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  dim: "\x1b[2m",
  bold: "\x1b[1m",
};

function log(msg) {
  console.log(msg);
}

function success(msg) {
  console.log(`${colors.green}✓${colors.reset} ${msg}`);
}

function error(msg) {
  console.error(`${colors.red}✗${colors.reset} ${msg}`);
}

function info(msg) {
  console.log(`${colors.blue}ℹ${colors.reset} ${msg}`);
}

function warn(msg) {
  console.log(`${colors.yellow}!${colors.reset} ${msg}`);
}

function checkOpCli() {
  try {
    execSync("op --version", { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function checkOpSignedIn() {
  try {
    execSync("op account get", { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function checkRpcHealth(chain, chainName) {
  try {
    const blockNumber = execSync(`cast block-number --rpc-url ${chain.rpc}`, {
      encoding: "utf8",
      timeout: 10000,
    }).trim();
    return { healthy: true, blockNumber: parseInt(blockNumber) };
  } catch (e) {
    return { healthy: false, error: e.message };
  }
}

function getFrozenInitcode(contractName) {
  const initcodePath = path.join(
    DEPLOYMENTS_DIR,
    contractName,
    "artifacts",
    `${contractName}.initcode`,
  );
  if (!fs.existsSync(initcodePath)) {
    return null;
  }
  return fs.readFileSync(initcodePath, "utf8").trim();
}

function getFrozenDeployedBytecode(contractName) {
  const deployedPath = path.join(
    DEPLOYMENTS_DIR,
    contractName,
    "artifacts",
    `${contractName}.deployed`,
  );
  if (!fs.existsSync(deployedPath)) {
    return null;
  }
  return fs.readFileSync(deployedPath, "utf8").trim();
}

function verifyFrozenBytecode(contractName) {
  const metadata = getDeploymentMetadata(contractName);
  if (!metadata) {
    return { valid: false, error: "No metadata found" };
  }

  const initcode = getFrozenInitcode(contractName);
  if (!initcode) {
    return { valid: false, error: "No frozen initcode found" };
  }

  const computedHash = execSync(`cast keccak ${initcode}`, {
    encoding: "utf8",
  }).trim();

  if (computedHash.toLowerCase() !== metadata.initcodeHash.toLowerCase()) {
    return {
      valid: false,
      error: `Initcode hash mismatch. Expected ${metadata.initcodeHash}, got ${computedHash}`,
    };
  }

  return { valid: true, initcodeHash: metadata.initcodeHash };
}

function checkAlreadyDeployed(chain, address) {
  try {
    const code = execSync(`cast code ${address} --rpc-url ${chain.rpc}`, {
      encoding: "utf8",
      timeout: 10000,
    }).trim();
    return code !== "0x" && code !== "";
  } catch {
    return false;
  }
}

function verifyDeployedBytecode(chain, address, contractName) {
  const frozenBytecode = getFrozenDeployedBytecode(contractName);
  if (!frozenBytecode) {
    return { valid: false, error: "No frozen deployed bytecode found" };
  }

  try {
    const onChainBytecode = execSync(
      `cast code ${address} --rpc-url ${chain.rpc}`,
      {
        encoding: "utf8",
        timeout: 15000,
      },
    ).trim();

    if (onChainBytecode === "0x" || onChainBytecode === "") {
      return { valid: false, error: "No bytecode found at address" };
    }

    if (onChainBytecode.toLowerCase() !== frozenBytecode.toLowerCase()) {
      return {
        valid: false,
        error: "On-chain bytecode does not match frozen bytecode",
        onChainLength: onChainBytecode.length,
        frozenLength: frozenBytecode.length,
      };
    }

    return { valid: true };
  } catch (e) {
    return { valid: false, error: e.message };
  }
}

function getDeployerFromKey() {
  try {
    const cmd = `op read "${DEPLOYER_KEY_REF}" | xargs cast wallet address`;
    return execSync(cmd, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    return null;
  }
}

function getDeployerFromSalt(salt) {
  // First 20 bytes of salt = deployer address
  return "0x" + salt.slice(2, 42);
}

function verifyDeployerAddress() {
  info("Verifying deployer address matches salt...");

  const deployerFromKey = getDeployerFromKey();
  if (!deployerFromKey) {
    error("Failed to get deployer address from 1Password");
    return { valid: false, address: null };
  }

  const expectedFromSalt = getDeployerFromSalt(CORE_SALT);

  if (deployerFromKey.toLowerCase() !== expectedFromSalt.toLowerCase()) {
    error(`Deployer address mismatch!`);
    log("");
    log(`  Salt requires: ${colors.green}${expectedFromSalt}${colors.reset}`);
    log(`  Your key:      ${colors.red}${deployerFromKey}${colors.reset}`);
    log("");
    log("  The private key in 1Password doesn't match the salt.");
    log("  Either update the salt or use a different deployer key.");
    return { valid: false, address: null };
  }

  success(`Deployer verified: ${deployerFromKey}`);
  return { valid: true, address: deployerFromKey };
}

function getDeploymentMetadata(contractName) {
  const metadataPath = path.join(
    DEPLOYMENTS_DIR,
    contractName,
    "metadata.json",
  );
  if (!fs.existsSync(metadataPath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(metadataPath, "utf8"));
}

function generateDeploymentId() {
  // Generate a UUID v4
  return crypto.randomUUID();
}

function addDeploymentRecord(contractName, deployer, address, salt, chainName) {
  const metadataPath = path.join(
    DEPLOYMENTS_DIR,
    contractName,
    "metadata.json",
  );
  const metadata = getDeploymentMetadata(contractName);
  if (!metadata) {
    error(`No metadata found for ${contractName}`);
    return false;
  }

  // Ensure deployments array exists
  if (!metadata.deployments) {
    metadata.deployments = [];
  }

  // Find existing deployment for this salt (salt determines address)
  let deployment = metadata.deployments.find(
    (d) => d.salt.toLowerCase() === salt.toLowerCase(),
  );

  if (deployment) {
    // Add chain if not already present
    if (!deployment.chains.includes(chainName)) {
      deployment.chains.push(chainName);
    }
  } else {
    // Create new deployment record with ID
    const id = generateDeploymentId();
    metadata.deployments.push({
      id,
      deployer,
      address,
      salt,
      chains: [chainName],
    });
  }

  fs.writeFileSync(metadataPath, JSON.stringify(metadata, null, 2));
  return true;
}

function findDeploymentById(metadata, id) {
  if (!metadata?.deployments) return null;
  return metadata.deployments.find((d) => d.id === id);
}

function findDeploymentBySalt(metadata, salt) {
  if (!metadata?.deployments) return null;
  return metadata.deployments.find(
    (d) => d.salt.toLowerCase() === salt.toLowerCase(),
  );
}

function verifyContracts(chainName, deploymentId = null) {
  const chain = CHAINS[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    return false;
  }

  log("");
  log(`${colors.blue}Verifying contracts on ${chainName}...${colors.reset}`);
  log("");

  const coreMetadata = getDeploymentMetadata("SpritzPayCore");
  const routerMetadata = getDeploymentMetadata("SpritzRouter");

  let coreDeployment, routerDeployment;

  if (deploymentId) {
    // Find core deployment by ID
    coreDeployment = findDeploymentById(coreMetadata, deploymentId);

    if (!coreDeployment) {
      error(`No Core deployment found with ID: ${deploymentId}`);
      log("");
      log("Available deployments:");
      listDeployments();
      return false;
    }

    // Find matching router by deployer and chain
    routerDeployment = routerMetadata?.deployments?.find(
      (r) =>
        r.deployer.toLowerCase() === coreDeployment.deployer.toLowerCase() &&
        r.chains.includes(chainName),
    );

    if (!routerDeployment) {
      error(
        `No Router deployment found for deployer ${coreDeployment.deployer} on ${chainName}`,
      );
      return false;
    }
  } else {
    // Find deployment by salt (from env vars)
    coreDeployment = findDeploymentBySalt(coreMetadata, CORE_SALT);
    routerDeployment = findDeploymentBySalt(routerMetadata, ROUTER_SALT);

    if (!coreDeployment?.address) {
      error(`SpritzPayCore has not been deployed yet with salt ${CORE_SALT}`);
      return false;
    }
    if (!routerDeployment?.address) {
      error(`SpritzRouter has not been deployed yet with salt ${ROUTER_SALT}`);
      return false;
    }
  }

  const coreAddress = coreDeployment.address;
  const routerAddress = routerDeployment.address;

  info(`Deployment ID: ${coreDeployment.id}`);
  info(`Core: ${coreAddress}`);
  info(`Router: ${routerAddress}`);
  log("");

  const contracts = [
    { name: "SpritzPayCore", address: coreAddress },
    { name: "SpritzRouter", address: routerAddress },
  ];

  let allSuccess = true;

  for (const contract of contracts) {
    info(`Verifying ${contract.name} at ${contract.address}...`);

    // Build constructor args for router (core address)
    let constructorArgs = "";
    if (contract.name === "SpritzRouter") {
      // Router has constructor arg: address _core
      constructorArgs = `--constructor-args $(cast abi-encode "constructor(address)" ${coreAddress})`;
    }

    const cmd = `forge verify-contract ${contract.address} ${contract.name} --chain ${chain.chainId} --watch ${constructorArgs}`;

    try {
      execSync(cmd, { stdio: "inherit", cwd: path.join(__dirname, "..") });
      success(`${contract.name} verified`);
    } catch (e) {
      error(`Failed to verify ${contract.name}`);
      allSuccess = false;
    }
  }

  return allSuccess;
}

function computeCreate3Address(deployer, salt) {
  // CreateX _guard for [deployer][0x00][entropy] salt format:
  // guardedSalt = keccak256(bytes32(uint256(uint160(deployer))) ++ salt)
  // Then CREATE3 address = computeCreate3Address(guardedSalt, CREATEX)

  const CREATEX = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed";

  // Compute guarded salt: keccak256(deployer padded to 32 bytes ++ salt)
  const deployerPadded = deployer.toLowerCase().slice(2).padStart(64, "0");
  const saltHex = salt.slice(2);
  const guardedSalt = execSync(`cast keccak 0x${deployerPadded}${saltHex}`, {
    encoding: "utf8",
  }).trim();

  // CREATE3 proxy address = keccak256(0xff ++ factory ++ guardedSalt ++ proxyInitCodeHash)[12:]
  // Then deployed address = keccak256(0xd694 ++ proxyAddress ++ 0x01)[12:]
  // CreateX uses a specific proxy init code hash
  const proxyInitCodeHash =
    "0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f";

  // Compute proxy address
  const factoryHex = CREATEX.toLowerCase().slice(2);
  const guardedSaltHex = guardedSalt.slice(2);
  const proxyInputHex = `ff${factoryHex}${guardedSaltHex}${proxyInitCodeHash.slice(2)}`;
  const proxyHash = execSync(`cast keccak 0x${proxyInputHex}`, {
    encoding: "utf8",
  }).trim();
  const proxyAddress = "0x" + proxyHash.slice(-40);

  // Compute deployed address (CREATE from proxy with nonce 1)
  // RLP encode: 0xd6 0x94 <address> 0x01
  const deployedInputHex = `d694${proxyAddress.slice(2)}01`;
  const deployedHash = execSync(`cast keccak 0x${deployedInputHex}`, {
    encoding: "utf8",
  }).trim();
  const deployedAddress = "0x" + deployedHash.slice(-40);

  return deployedAddress;
}

function recordDeployment(chainName) {
  const chain = CHAINS[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    return false;
  }

  log("");
  log(`${colors.blue}Recording deployment on ${chainName}...${colors.reset}`);
  log("");

  const deployer = getDeployerFromSalt(CORE_SALT);
  info(`Deployer: ${deployer}`);

  // Compute addresses directly using the CreateX formula
  info("Computing expected addresses...");

  try {
    const coreAddress = computeCreate3Address(deployer, CORE_SALT);
    const routerAddress = computeCreate3Address(deployer, ROUTER_SALT);

    // Checksum the addresses
    const coreAddressChecksummed = execSync(
      `cast to-check-sum-address ${coreAddress}`,
      {
        encoding: "utf8",
      },
    ).trim();
    const routerAddressChecksummed = execSync(
      `cast to-check-sum-address ${routerAddress}`,
      {
        encoding: "utf8",
      },
    ).trim();

    info(`Core: ${coreAddressChecksummed}`);
    info(`Router: ${routerAddressChecksummed}`);

    // Verify contracts exist on-chain
    info("Verifying contracts exist on-chain...");

    const coreCode = execSync(
      `cast code ${coreAddressChecksummed} --rpc-url ${chain.rpc}`,
      {
        encoding: "utf8",
      },
    ).trim();

    if (coreCode === "0x" || coreCode === "") {
      error(`SpritzPayCore not deployed at ${coreAddressChecksummed}`);
      return false;
    }
    success("SpritzPayCore found on-chain");

    const routerCode = execSync(
      `cast code ${routerAddressChecksummed} --rpc-url ${chain.rpc}`,
      {
        encoding: "utf8",
      },
    ).trim();

    if (routerCode === "0x" || routerCode === "") {
      error(`SpritzRouter not deployed at ${routerAddressChecksummed}`);
      return false;
    }
    success("SpritzRouter found on-chain");

    // Update metadata
    info("Updating metadata...");

    addDeploymentRecord(
      "SpritzPayCore",
      deployer,
      coreAddressChecksummed,
      CORE_SALT,
      chainName,
    );
    success("Updated SpritzPayCore metadata");

    addDeploymentRecord(
      "SpritzRouter",
      deployer,
      routerAddressChecksummed,
      ROUTER_SALT,
      chainName,
    );
    success("Updated SpritzRouter metadata");

    log("");
    success(`Deployment recorded for ${chainName}`);
    log("");

    return true;
  } catch (e) {
    error(`Failed to record deployment: ${e.message}`);
    return false;
  }
}

function listChains() {
  log("");
  log(`${colors.blue}Available Chains${colors.reset}`);
  log("─".repeat(50));

  const mainnets = Object.entries(CHAINS).filter(([, c]) => !c.testnet);
  const testnets = Object.entries(CHAINS).filter(([, c]) => c.testnet);

  log("");
  log(`${colors.bold}Mainnets${colors.reset}`);
  for (const [name, config] of mainnets) {
    log(
      `  ${colors.green}${name.padEnd(15)}${colors.reset} ${colors.dim}${config.explorer}${colors.reset}`,
    );
  }

  log("");
  log(`${colors.bold}Testnets${colors.reset}`);
  for (const [name, config] of testnets) {
    log(
      `  ${colors.yellow}${name.padEnd(15)}${colors.reset} ${colors.dim}${config.explorer}${colors.reset}`,
    );
  }

  log("");
}

function listDeployments() {
  const coreMetadata = getDeploymentMetadata("SpritzPayCore");
  const routerMetadata = getDeploymentMetadata("SpritzRouter");

  if (!coreMetadata?.deployments?.length) {
    log("");
    info("No deployments recorded yet.");
    log("");
    return;
  }

  log("");
  log(`${colors.blue}Recorded Deployments${colors.reset}`);
  log("─".repeat(70));

  for (const coreDep of coreMetadata.deployments) {
    // Find matching router by deployer and overlapping chains
    const routerDep = routerMetadata?.deployments?.find(
      (r) =>
        r.deployer.toLowerCase() === coreDep.deployer.toLowerCase() &&
        r.chains.some((c) => coreDep.chains.includes(c)),
    );

    log("");
    log(`  ${colors.bold}Core:${colors.reset}   ${coreDep.id}`);
    log(
      `  ${colors.bold}Router:${colors.reset} ${routerDep?.id || "not found"}`,
    );
    log(`  ${colors.dim}Deployer:${colors.reset} ${coreDep.deployer}`);
    log(`  ${colors.dim}Core:${colors.reset}     ${coreDep.address}`);
    log(
      `  ${colors.dim}Router:${colors.reset}   ${routerDep?.address || "unknown"}`,
    );
    log(`  ${colors.dim}Chains:${colors.reset}   ${coreDep.chains.join(", ")}`);
  }

  log("");
}

function runPreflightChecks(chainName, chain) {
  log("");
  log(`${colors.bold}Pre-flight Checks${colors.reset}`);
  log("─".repeat(50));
  log("");

  let allPassed = true;

  // 1. Check frozen bytecode exists and matches
  info("Verifying frozen bytecode...");
  for (const contractName of ["SpritzPayCore", "SpritzRouter"]) {
    const result = verifyFrozenBytecode(contractName);
    if (!result.valid) {
      error(`${contractName}: ${result.error}`);
      allPassed = false;
    } else {
      success(`${contractName} frozen bytecode verified`);
    }
  }

  // 2. Check RPC health
  log("");
  info(`Testing RPC connection to ${chainName}...`);
  const rpcResult = checkRpcHealth(chain, chainName);
  if (!rpcResult.healthy) {
    error(`RPC unreachable: ${rpcResult.error}`);
    allPassed = false;
  } else {
    success(`RPC healthy (block ${rpcResult.blockNumber})`);
  }

  // 3. Compute expected addresses and check if already deployed
  log("");
  info("Computing deterministic addresses...");
  const deployer = getDeployerFromSalt(CORE_SALT);
  const coreAddress = computeCreate3Address(deployer, CORE_SALT);
  const routerAddress = computeCreate3Address(deployer, ROUTER_SALT);

  const coreChecksummed = execSync(`cast to-check-sum-address ${coreAddress}`, {
    encoding: "utf8",
  }).trim();
  const routerChecksummed = execSync(
    `cast to-check-sum-address ${routerAddress}`,
    { encoding: "utf8" },
  ).trim();

  log(`  Core:   ${coreChecksummed}`);
  log(`  Router: ${routerChecksummed}`);

  // 4. Check if already deployed
  log("");
  info("Checking if contracts already deployed...");

  const coreDeployed = checkAlreadyDeployed(chain, coreChecksummed);
  const routerDeployed = checkAlreadyDeployed(chain, routerChecksummed);

  if (coreDeployed && routerDeployed) {
    warn("Both contracts already deployed on this chain");
    return {
      passed: true,
      alreadyDeployed: true,
      coreAddress: coreChecksummed,
      routerAddress: routerChecksummed,
    };
  } else if (coreDeployed || routerDeployed) {
    error("Partial deployment detected - manual intervention required");
    log(`  Core deployed: ${coreDeployed}`);
    log(`  Router deployed: ${routerDeployed}`);
    allPassed = false;
  } else {
    success("Addresses available for deployment");
  }

  return {
    passed: allPassed,
    alreadyDeployed: false,
    coreAddress: coreChecksummed,
    routerAddress: routerChecksummed,
  };
}

function showDeploymentPlan(chainName, chain, coreAddress, routerAddress) {
  const deployer = getDeployerFromSalt(CORE_SALT);
  const coreMetadata = getDeploymentMetadata("SpritzPayCore");
  const routerMetadata = getDeploymentMetadata("SpritzRouter");

  log("");
  log(
    `${colors.blue}═══════════════════════════════════════════════════════════${colors.reset}`,
  );
  log(`${colors.blue}  Deployment Plan${colors.reset}`);
  log(
    `${colors.blue}═══════════════════════════════════════════════════════════${colors.reset}`,
  );
  log("");
  log(`  ${colors.bold}Chain:${colors.reset}       ${chainName} ${chain.testnet ? "(testnet)" : colors.yellow + "(MAINNET)" + colors.reset}`);
  log(`  ${colors.bold}Chain ID:${colors.reset}    ${chain.chainId}`);
  log(`  ${colors.bold}RPC:${colors.reset}         ${chain.rpc.slice(0, 50)}...`);
  log(`  ${colors.bold}Explorer:${colors.reset}    ${chain.explorer}`);
  log("");
  log(`  ${colors.bold}Deployer:${colors.reset}    ${deployer}`);
  log(`  ${colors.bold}Admin:${colors.reset}       ${chain.admin}`);
  log("");
  log(`  ${colors.bold}Contracts:${colors.reset}`);
  log(`    SpritzPayCore  → ${coreAddress}`);
  log(`      ${colors.dim}Initcode hash: ${coreMetadata?.initcodeHash?.slice(0, 22)}...${colors.reset}`);
  log(`    SpritzRouter   → ${routerAddress}`);
  log(`      ${colors.dim}Initcode hash: ${routerMetadata?.initcodeHash?.slice(0, 22)}...${colors.reset}`);
  log("");
  log(`  ${colors.bold}Salts:${colors.reset}`);
  log(`    Core:   ${colors.dim}${CORE_SALT.slice(0, 22)}...${colors.reset}`);
  log(`    Router: ${colors.dim}${ROUTER_SALT.slice(0, 22)}...${colors.reset}`);
  log("");
}

function deploy(chainName, broadcast = false) {
  const chain = CHAINS[chainName];

  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    log("");
    log(
      `Run ${colors.dim}./deploy --list${colors.reset} to see available chains`,
    );
    process.exit(1);
  }

  // Run pre-flight checks
  const preflight = runPreflightChecks(chainName, chain);

  if (!preflight.passed) {
    log("");
    error("Pre-flight checks failed. Aborting deployment.");
    process.exit(1);
  }

  // Show deployment plan
  showDeploymentPlan(
    chainName,
    chain,
    preflight.coreAddress,
    preflight.routerAddress,
  );

  if (preflight.alreadyDeployed) {
    log(
      `${colors.green}Contracts already deployed at expected addresses.${colors.reset}`,
    );
    log("");
    log(`To record this deployment: ${colors.dim}./deploy --record ${chainName}${colors.reset}`);
    log("");
    process.exit(0);
  }

  if (!broadcast) {
    // Dry run - simulate deployment
    log(`${colors.yellow}─── Simulation Mode ───${colors.reset}`);
    log("");
    info("Running deployment simulation...");
    log("");

    const env = {
      ...process.env,
      ADMIN_ADDRESS: chain.admin,
      CORE_SALT: CORE_SALT,
      ROUTER_SALT: ROUTER_SALT,
    };

    const result = spawnSync(
      "forge",
      [
        "script",
        "script/Deploy.s.sol:DeploySpritzForkTest",
        "--rpc-url",
        chain.rpc,
      ],
      {
        stdio: "inherit",
        env,
        cwd: path.join(__dirname, ".."),
      },
    );

    if (result.status !== 0) {
      log("");
      error("Simulation failed");
      process.exit(1);
    }

    log("");
    success("Simulation completed successfully");
    log("");
    log(`${colors.bold}To deploy for real:${colors.reset}`);
    log(`  ${colors.dim}./deploy ${chainName} --broadcast${colors.reset}`);
    log("");
    process.exit(0);
  }

  // Real deployment - verify 1Password first
  log(`${colors.red}─── LIVE DEPLOYMENT ───${colors.reset}`);
  log("");

  if (!checkOpCli()) {
    error("1Password CLI not installed");
    log("");
    log("  Install: https://developer.1password.com/docs/cli/get-started");
    process.exit(1);
  }
  success("1Password CLI found");

  if (!checkOpSignedIn()) {
    error("Not signed in to 1Password");
    log("");
    log(`  Run: ${colors.dim}op signin${colors.reset}`);
    process.exit(1);
  }
  success("1Password signed in");

  const verifyResult = verifyDeployerAddress();
  if (!verifyResult.valid) {
    process.exit(1);
  }

  // Final confirmation
  log("");
  if (!chain.testnet) {
    log(
      `${colors.red}${colors.bold}⚠️  WARNING: MAINNET DEPLOYMENT${colors.reset}`,
    );
    log("");
    log("  This will deploy contracts to a production network.");
    log("  This action cannot be undone.");
    log("");
    log("  Press Ctrl+C to cancel, or wait 10 seconds to continue...");
    log("");

    try {
      execSync("sleep 10", { stdio: "inherit" });
    } catch {
      log("");
      info("Cancelled");
      process.exit(0);
    }
  } else {
    log("  Press Ctrl+C to cancel, or wait 3 seconds to continue...");
    log("");
    try {
      execSync("sleep 3", { stdio: "inherit" });
    } catch {
      log("");
      info("Cancelled");
      process.exit(0);
    }
  }

  // Execute deployment
  info("Broadcasting deployment transaction...");
  log("");

  const env = {
    ...process.env,
    ADMIN_ADDRESS: chain.admin,
    CORE_SALT: CORE_SALT,
    ROUTER_SALT: ROUTER_SALT,
  };

  const forgeCmd = `forge script script/Deploy.s.sol:DeploySpritz --rpc-url ${chain.rpc} --broadcast --private-key $(op read "${DEPLOYER_KEY_REF}")`;
  const result = spawnSync("sh", ["-c", forgeCmd], {
    stdio: "inherit",
    env,
    cwd: path.join(__dirname, ".."),
  });

  if (result.status !== 0) {
    log("");
    error("Deployment failed");
    process.exit(1);
  }

  log("");
  success("Deployment transaction broadcast!");

  // Verify deployed bytecode matches frozen bytecode
  log("");
  info("Verifying deployed bytecode matches frozen bytecode...");

  // Wait a moment for RPC to index
  execSync("sleep 3");

  const coreVerify = verifyDeployedBytecode(
    chain,
    preflight.coreAddress,
    "SpritzPayCore",
  );
  if (!coreVerify.valid) {
    error(`SpritzPayCore bytecode verification failed: ${coreVerify.error}`);
  } else {
    success("SpritzPayCore bytecode matches frozen bytecode");
  }

  const routerVerify = verifyDeployedBytecode(
    chain,
    preflight.routerAddress,
    "SpritzRouter",
  );
  if (!routerVerify.valid) {
    error(`SpritzRouter bytecode verification failed: ${routerVerify.error}`);
  } else {
    success("SpritzRouter bytecode matches frozen bytecode");
  }

  // Record deployment
  log("");
  recordDeployment(chainName);

  log(
    `${colors.green}═══════════════════════════════════════════════════════════${colors.reset}`,
  );
  log(`${colors.green}  Deployment to ${chainName} complete!${colors.reset}`);
  log(
    `${colors.green}═══════════════════════════════════════════════════════════${colors.reset}`,
  );
  log("");
  log(`${colors.bold}Next steps:${colors.reset}`);
  log(
    `  1. Verify on explorer: ${colors.dim}./deploy --verify <id> ${chainName}${colors.reset}`,
  );
  log(`  2. Set up payment tokens: core.addPaymentToken(token, recipient)`);
  log(`  3. Set swap module: router.setSwapModule(swapModule)`);
  log("");
}

function printUsage() {
  log("");
  log(
    `${colors.blue}Deploy Script${colors.reset} - Deploy Spritz contracts with 1Password`,
  );
  log("");
  log(`${colors.bold}Commands:${colors.reset}`);
  log("");
  log(`  ${colors.green}./deploy <chain>${colors.reset}`);
  log(`      Run pre-flight checks and simulate deployment (safe, no tx)`);
  log("");
  log(`  ${colors.green}./deploy <chain> --broadcast${colors.reset}`);
  log(`      Deploy contracts to the chain (requires 1Password)`);
  log("");
  log(`  ${colors.green}./deploy --list${colors.reset}`);
  log(`      List all supported chains`);
  log("");
  log(`  ${colors.green}./deploy --deployments${colors.reset}`);
  log(`      List all recorded deployments`);
  log("");
  log(`  ${colors.green}./deploy --record <chain>${colors.reset}`);
  log(`      Record an existing deployment to metadata`);
  log("");
  log(`  ${colors.green}./deploy --verify <id> <chain>${colors.reset}`);
  log(`      Verify contracts on block explorer`);
  log("");
  log(`  ${colors.green}./deploy --check${colors.reset}`);
  log(`      Verify 1Password deployer key matches salt`);
  log("");
  log(`${colors.bold}Examples:${colors.reset}`);
  log(`  ${colors.dim}./deploy base${colors.reset}                    # Simulate deployment to Base`);
  log(`  ${colors.dim}./deploy base --broadcast${colors.reset}        # Deploy to Base for real`);
  log(`  ${colors.dim}./deploy --verify abc123 base${colors.reset}    # Verify on Basescan`);
  log("");
  log(`${colors.bold}Workflow:${colors.reset}`);
  log(`  1. Freeze contracts:  ${colors.dim}./freeze SpritzPayCore && ./freeze SpritzRouter${colors.reset}`);
  log(`  2. Simulate:          ${colors.dim}./deploy <chain>${colors.reset}`);
  log(`  3. Deploy:            ${colors.dim}./deploy <chain> --broadcast${colors.reset}`);
  log(`  4. Verify:            ${colors.dim}./deploy --verify <id> <chain>${colors.reset}`);
  log("");
}

// Parse args
const args = process.argv.slice(2);

if (args.length === 0 || args[0] === "--help" || args[0] === "-h") {
  printUsage();
  process.exit(0);
}

if (args[0] === "--list" || args[0] === "-l") {
  listChains();
  process.exit(0);
}

if (args[0] === "--deployments" || args[0] === "-d") {
  listDeployments();
  process.exit(0);
}

if (args[0] === "--check" || args[0] === "-c") {
  log("");
  if (!checkOpCli()) {
    error("1Password CLI not installed");
    process.exit(1);
  }
  success("1Password CLI found");

  if (!checkOpSignedIn()) {
    error("Not signed in to 1Password");
    process.exit(1);
  }
  success("1Password signed in");

  const result = verifyDeployerAddress();
  if (!result.valid) {
    process.exit(1);
  }
  log("");
  process.exit(0);
}

if (args[0] === "--record" || args[0] === "-r") {
  const chainName = args[1];
  if (!chainName) {
    error("Missing chain name");
    log(`  Usage: ./deploy --record <chain>`);
    process.exit(1);
  }
  const ok = recordDeployment(chainName);
  process.exit(ok ? 0 : 1);
}

if (args[0] === "--verify" || args[0] === "-v") {
  const deploymentId = args[1];
  const chainName = args[2];
  if (!deploymentId || !chainName) {
    error("Missing deployment ID or chain name");
    log(`  Usage: ./deploy --verify <deployment-id> <chain>`);
    log("");
    log("  Run --deployments to see available deployment IDs");
    process.exit(1);
  }
  const ok = verifyContracts(chainName, deploymentId);
  process.exit(ok ? 0 : 1);
}

// Deployment command requires a chain name
const chainName = args[0];
if (chainName.startsWith("-")) {
  error(`Unknown option: ${chainName}`);
  printUsage();
  process.exit(1);
}

const broadcast = args.includes("--broadcast") || args.includes("-b");

deploy(chainName, broadcast);
