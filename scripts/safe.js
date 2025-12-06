#!/usr/bin/env node

/**
 * Safe Admin CLI - Manage Spritz contracts via Safe multisig
 *
 * Commands:
 *   bun safe status <chain>                  Show current contract configuration
 *   bun safe list <chain>                    List pending transactions
 *   bun safe sign <chain> <safeTxHash>       Sign a pending transaction
 *   bun safe execute <chain> <safeTxHash>    Execute a fully-signed transaction
 *
 * Actions:
 *   bun safe setSwapModule <chain> <moduleAddress>         Set the swap module on Router
 *   bun safe addPaymentToken <chain> <token> <recipient>   Add a payment token on Core
 *   bun safe removePaymentToken <chain> <token>            Remove a payment token from Core
 *   bun safe sweep <chain> <contract> <token> <to>         Sweep tokens from a contract
 *
 * Setup:
 *   1. Install deps: bun add @safe-global/protocol-kit @safe-global/api-kit ethers
 *   2. Configure .env with signer 1Password references
 */

const { execSync } = require("child_process");
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// =============================================================================
// CONFIGURATION - Loaded from config.json + .env
// =============================================================================

const CONFIG_PATH = path.join(__dirname, "..", "config.json");
const ENV_PATH = path.join(__dirname, "..", ".env");
const DEPLOYMENTS_DIR = path.join(__dirname, "..", "deployments");

function loadEnv() {
  if (!fs.existsSync(ENV_PATH)) {
    return {};
  }
  const env = {};
  const content = fs.readFileSync(ENV_PATH, "utf8");
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const [key, ...valueParts] = trimmed.split("=");
    if (key && valueParts.length > 0) {
      env[key.trim()] = valueParts.join("=").trim();
    }
  }
  return env;
}

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    console.error("config.json not found. Run from project root.");
    process.exit(1);
  }
  return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
}

function loadSignersFromEnv(env) {
  const signers = [];
  for (let i = 1; i <= 10; i++) {
    const name = env[`SIGNER_${i}_NAME`];
    const address = env[`SIGNER_${i}_ADDRESS`];
    const keyRef = env[`SIGNER_${i}_KEY_REF`];
    if (name && keyRef) {
      signers.push({ name, address: address || "", keyRef });
    }
  }
  return signers;
}

const envVars = loadEnv();
const config = loadConfig();

// Extract config values
const SAFE_ADDRESS = config.admin.safe;
const RPC_KEY = process.env.RPC_KEY || envVars.RPC_KEY || "";
const SIGNERS = loadSignersFromEnv(envVars);

if (SIGNERS.length === 0) {
  console.error("No signers configured. Create .env file with SIGNER_1_NAME, SIGNER_1_KEY_REF, etc.");
  console.error("See .env.example for format.");
  process.exit(1);
}

// Build chain configurations from config
function buildChains() {
  const chains = {};
  for (const [name, chainConfig] of Object.entries(config.chains)) {
    const rpc = chainConfig.rpc.replace("${alchemyKey}", RPC_KEY);
    chains[name] = {
      rpc,
      chainId: chainConfig.chainId,
      safe: SAFE_ADDRESS,
      safeService: chainConfig.safeService,
    };
  }
  return chains;
}

const CHAINS = buildChains();

function getSignerByName(name) {
  return SIGNERS.find((s) => s.name === name);
}

function getSignerByAddress(address) {
  return SIGNERS.find(
    (s) => s.address.toLowerCase() === address.toLowerCase(),
  );
}

// Contract ABIs (minimal for admin functions)
const ROUTER_ABI = [
  "function setSwapModule(address newSwapModule) external",
  "function sweep(address token, address to) external",
  "function owner() view returns (address)",
  "function swapModule() view returns (address)",
];

const CORE_ABI = [
  "function addPaymentToken(address token, address recipient) external",
  "function removePaymentToken(address token) external",
  "function sweep(address token, address to) external",
  "function owner() view returns (address)",
  "function isAcceptedToken(address token) view returns (bool)",
  "function paymentRecipient(address token) view returns (address)",
  "function acceptedPaymentTokens() view returns (address[])",
];

// =============================================================================
// UTILITIES
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

function getPrivateKey(keyRef) {
  try {
    return execSync(`op read "${keyRef}"`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    return null;
  }
}

function listSigners() {
  log("");
  log(`${colors.blue}Configured Signers${colors.reset}`);
  log("─".repeat(50));
  log("");
  for (const signer of SIGNERS) {
    log(`  ${colors.bold}${signer.name}${colors.reset}`);
    log(`    Address: ${signer.address || "(not set)"}`);
    log(`    Key Ref: ${colors.dim}${signer.keyRef}${colors.reset}`);
    log("");
  }
}

function getDeploymentAddresses(chainName) {
  const coreMetadataPath = path.join(DEPLOYMENTS_DIR, "SpritzPayCore", "metadata.json");
  const routerMetadataPath = path.join(DEPLOYMENTS_DIR, "SpritzRouter", "metadata.json");

  if (!fs.existsSync(coreMetadataPath) || !fs.existsSync(routerMetadataPath)) {
    return null;
  }

  const coreMetadata = JSON.parse(fs.readFileSync(coreMetadataPath, "utf8"));
  const routerMetadata = JSON.parse(fs.readFileSync(routerMetadataPath, "utf8"));

  // Find deployment for this chain
  const coreDep = coreMetadata.deployments?.find((d) =>
    d.chains.includes(chainName),
  );
  const routerDep = routerMetadata.deployments?.find((d) =>
    d.chains.includes(chainName),
  );

  if (!coreDep || !routerDep) {
    return null;
  }

  return {
    core: coreDep.address,
    router: routerDep.address,
  };
}

// =============================================================================
// SAFE SDK INITIALIZATION
// =============================================================================

let Safe, SafeApiKit;

async function loadSafeSDK() {
  if (!Safe) {
    try {
      const protocolKit = await import("@safe-global/protocol-kit");
      const apiKit = await import("@safe-global/api-kit");
      Safe = protocolKit.default;
      SafeApiKit = apiKit.default;
    } catch (e) {
      error("Safe SDK not installed. Run:");
      log("");
      log("  bun add @safe-global/protocol-kit @safe-global/api-kit ethers");
      log("");
      process.exit(1);
    }
  }
}

async function initSafe(chainName, signerName = null) {
  await loadSafeSDK();

  const chain = CHAINS[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    process.exit(1);
  }

  if (!chain.safe) {
    error(`No Safe address configured for ${chainName}`);
    process.exit(1);
  }

  // Get signer config
  let signerConfig;
  if (signerName) {
    signerConfig = getSignerByName(signerName);
    if (!signerConfig) {
      error(`Unknown signer: ${signerName}`);
      log("");
      log("Available signers:");
      for (const s of SIGNERS) {
        log(`  - ${s.name}`);
      }
      process.exit(1);
    }
  } else {
    // Default to first signer
    signerConfig = SIGNERS[0];
  }

  info(`Using signer: ${signerConfig.name}`);

  const privateKey = getPrivateKey(signerConfig.keyRef);
  if (!privateKey) {
    error(`Failed to get key from 1Password: ${signerConfig.keyRef}`);
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(chain.rpc);

  const protocolKit = await Safe.init({
    provider: chain.rpc,
    signer: privateKey,
    safeAddress: chain.safe,
  });

  const apiKit = new SafeApiKit({
    chainId: BigInt(chain.chainId),
    txServiceUrl: chain.safeService,
  });

  const signer = new ethers.Wallet(privateKey, provider);

  return { protocolKit, apiKit, signer, chain, safeAddress: chain.safe, signerConfig };
}

// =============================================================================
// COMMANDS
// =============================================================================

async function listPendingTransactions(chainName) {
  const { apiKit, safeAddress } = await initSafe(chainName);

  log("");
  log(`${colors.blue}Pending Transactions for ${chainName}${colors.reset}`);
  log("─".repeat(70));

  try {
    const pending = await apiKit.getPendingTransactions(safeAddress);

    if (!pending.results || pending.results.length === 0) {
      log("");
      info("No pending transactions");
      log("");
      return;
    }

    for (const tx of pending.results) {
      log("");
      log(`  ${colors.bold}Hash:${colors.reset} ${tx.safeTxHash}`);
      log(`  ${colors.dim}To:${colors.reset} ${tx.to}`);
      log(`  ${colors.dim}Value:${colors.reset} ${tx.value}`);
      log(`  ${colors.dim}Data:${colors.reset} ${tx.data?.slice(0, 50)}...`);
      log(`  ${colors.dim}Confirmations:${colors.reset} ${tx.confirmations?.length || 0}/${tx.confirmationsRequired}`);
      log(`  ${colors.dim}Nonce:${colors.reset} ${tx.nonce}`);
    }

    log("");
  } catch (e) {
    error(`Failed to fetch pending transactions: ${e.message}`);
  }
}

async function proposeTransaction(chainName, transactions, description) {
  const { protocolKit, apiKit, signer, safeAddress } = await initSafe(chainName);

  log("");
  info(`Proposing transaction to Safe on ${chainName}...`);
  log("");

  // Create the Safe transaction
  const safeTransaction = await protocolKit.createTransaction({
    transactions,
  });

  // Get transaction hash and sign
  const safeTxHash = await protocolKit.getTransactionHash(safeTransaction);
  const signature = await protocolKit.signHash(safeTxHash);

  // Propose to Safe Transaction Service
  await apiKit.proposeTransaction({
    safeAddress,
    safeTransactionData: safeTransaction.data,
    safeTxHash,
    senderAddress: signer.address,
    senderSignature: signature.data,
    origin: "Spritz Safe CLI",
  });

  success("Transaction proposed!");
  log("");
  log(`  ${colors.bold}Safe TX Hash:${colors.reset} ${safeTxHash}`);
  log(`  ${colors.bold}Description:${colors.reset} ${description}`);
  log("");
  log(`  Other signers can now sign via Safe UI or:`);
  log(`  ${colors.dim}bun safe sign ${chainName} ${safeTxHash}${colors.reset}`);
  log("");

  return safeTxHash;
}

async function signTransaction(chainName, safeTxHash) {
  const { protocolKit, apiKit, signer, safeAddress } = await initSafe(chainName);

  log("");
  info(`Signing transaction ${safeTxHash.slice(0, 18)}...`);

  // Sign the hash
  const signature = await protocolKit.signHash(safeTxHash);

  // Submit confirmation
  await apiKit.confirmTransaction(safeTxHash, signature.data);

  success("Transaction signed!");
  log("");

  // Check if ready to execute
  const tx = await apiKit.getTransaction(safeTxHash);
  const confirmations = tx.confirmations?.length || 0;
  const threshold = tx.confirmationsRequired;

  log(`  ${colors.bold}Confirmations:${colors.reset} ${confirmations}/${threshold}`);

  if (confirmations >= threshold) {
    log("");
    log(`  ${colors.green}Ready to execute!${colors.reset}`);
    log(`  ${colors.dim}bun safe execute ${chainName} ${safeTxHash}${colors.reset}`);
  } else {
    log(`  ${colors.yellow}Waiting for more signatures${colors.reset}`);
  }

  log("");
}

async function executeTransaction(chainName, safeTxHash) {
  const { protocolKit, apiKit } = await initSafe(chainName);

  log("");
  info(`Executing transaction ${safeTxHash.slice(0, 18)}...`);

  // Get transaction from service
  const tx = await apiKit.getTransaction(safeTxHash);

  // Check threshold
  const confirmations = tx.confirmations?.length || 0;
  const threshold = tx.confirmationsRequired;

  if (confirmations < threshold) {
    error(`Not enough signatures: ${confirmations}/${threshold}`);
    process.exit(1);
  }

  // Execute
  const response = await protocolKit.executeTransaction(tx);
  const receipt = await response.transactionResponse?.wait();

  success("Transaction executed!");
  log("");
  log(`  ${colors.bold}TX Hash:${colors.reset} ${receipt?.hash || response.hash}`);
  log("");
}

// =============================================================================
// ACTION HANDLERS
// =============================================================================

async function setSwapModule(chainName, moduleAddress) {
  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const iface = new ethers.Interface(ROUTER_ABI);
  const data = iface.encodeFunctionData("setSwapModule", [moduleAddress]);

  const transactions = [
    {
      to: addresses.router,
      data,
      value: "0",
    },
  ];

  await proposeTransaction(
    chainName,
    transactions,
    `Set swap module to ${moduleAddress}`,
  );
}

async function addPaymentToken(chainName, token, recipient) {
  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const iface = new ethers.Interface(CORE_ABI);
  const data = iface.encodeFunctionData("addPaymentToken", [token, recipient]);

  const transactions = [
    {
      to: addresses.core,
      data,
      value: "0",
    },
  ];

  await proposeTransaction(
    chainName,
    transactions,
    `Add payment token ${token} with recipient ${recipient}`,
  );
}

async function removePaymentToken(chainName, token) {
  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const iface = new ethers.Interface(CORE_ABI);
  const data = iface.encodeFunctionData("removePaymentToken", [token]);

  const transactions = [
    {
      to: addresses.core,
      data,
      value: "0",
    },
  ];

  await proposeTransaction(chainName, transactions, `Remove payment token ${token}`);
}

async function sweep(chainName, contract, token, to) {
  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const targetAddress = contract === "core" ? addresses.core : addresses.router;
  const abi = contract === "core" ? CORE_ABI : ROUTER_ABI;

  const iface = new ethers.Interface(abi);
  const data = iface.encodeFunctionData("sweep", [token, to]);

  const transactions = [
    {
      to: targetAddress,
      data,
      value: "0",
    },
  ];

  await proposeTransaction(
    chainName,
    transactions,
    `Sweep ${token} from ${contract} to ${to}`,
  );
}

async function showStatus(chainName) {
  const chain = CHAINS[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    process.exit(1);
  }

  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(chain.rpc);
  const core = new ethers.Contract(addresses.core, CORE_ABI, provider);
  const router = new ethers.Contract(addresses.router, ROUTER_ABI, provider);

  log("");
  log(`${colors.blue}Contract Status on ${chainName}${colors.reset}`);
  log("─".repeat(70));
  log("");

  log(`${colors.bold}SpritzPayCore${colors.reset} (${addresses.core})`);
  const coreOwner = await core.owner();
  log(`  Owner: ${coreOwner}`);

  const tokens = await core.acceptedPaymentTokens();
  log(`  Payment Tokens: ${tokens.length}`);
  for (const token of tokens) {
    const recipient = await core.paymentRecipient(token);
    log(`    ${colors.dim}${token} → ${recipient}${colors.reset}`);
  }

  log("");
  log(`${colors.bold}SpritzRouter${colors.reset} (${addresses.router})`);
  const routerOwner = await router.owner();
  const swapModule = await router.swapModule();
  log(`  Owner: ${routerOwner}`);
  log(`  Swap Module: ${swapModule}`);

  log("");
}

// =============================================================================
// CLI
// =============================================================================

function printUsage() {
  log("");
  log(`${colors.blue}Safe Admin CLI${colors.reset} - Manage Spritz contracts via Safe multisig`);
  log("");
  log(`${colors.bold}Commands:${colors.reset}`);
  log("");
  log(`  ${colors.green}bun safe status <chain>${colors.reset}`);
  log(`      Show current contract configuration`);
  log("");
  log(`  ${colors.green}bun safe list <chain>${colors.reset}`);
  log(`      List pending Safe transactions`);
  log("");
  log(`  ${colors.green}bun safe sign <chain> <safeTxHash>${colors.reset}`);
  log(`      Sign a pending transaction`);
  log("");
  log(`  ${colors.green}bun safe execute <chain> <safeTxHash>${colors.reset}`);
  log(`      Execute a fully-signed transaction`);
  log("");
  log(`${colors.bold}Propose Actions:${colors.reset}`);
  log("");
  log(`  ${colors.green}bun safe setSwapModule <chain> <moduleAddress>${colors.reset}`);
  log(`      Set the swap module on Router`);
  log("");
  log(`  ${colors.green}bun safe addPaymentToken <chain> <token> <recipient>${colors.reset}`);
  log(`      Add a payment token on Core`);
  log("");
  log(`  ${colors.green}bun safe removePaymentToken <chain> <token>${colors.reset}`);
  log(`      Remove a payment token from Core`);
  log("");
  log(`  ${colors.green}bun safe sweep <chain> <core|router> <token> <to>${colors.reset}`);
  log(`      Sweep tokens from a contract`);
  log("");
  log(`${colors.bold}Examples:${colors.reset}`);
  log(`  ${colors.dim}bun safe status base${colors.reset}`);
  log(`  ${colors.dim}bun safe setSwapModule base 0x1234...${colors.reset}`);
  log(`  ${colors.dim}bun safe addPaymentToken base 0xUSDC... 0xRecipient...${colors.reset}`);
  log(`  ${colors.dim}bun safe list base${colors.reset}`);
  log(`  ${colors.dim}bun safe sign base 0xsafeTxHash...${colors.reset}`);
  log(`  ${colors.dim}bun safe execute base 0xsafeTxHash...${colors.reset}`);
  log("");
  log(`${colors.bold}Environment:${colors.reset}`);
  log(`  Configure signers in .env (see .env.example)`);
  log(`  RPC_KEY            Alchemy API key`);
  log("");
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") {
    printUsage();
    process.exit(0);
  }

  const command = args[0];

  try {
    switch (command) {
      case "status":
        if (!args[1]) {
          error("Missing chain name");
          process.exit(1);
        }
        await showStatus(args[1]);
        break;

      case "list":
        if (!args[1]) {
          error("Missing chain name");
          process.exit(1);
        }
        await listPendingTransactions(args[1]);
        break;

      case "sign":
        if (!args[1] || !args[2]) {
          error("Usage: bun safe sign <chain> <safeTxHash>");
          process.exit(1);
        }
        await signTransaction(args[1], args[2]);
        break;

      case "execute":
        if (!args[1] || !args[2]) {
          error("Usage: bun safe execute <chain> <safeTxHash>");
          process.exit(1);
        }
        await executeTransaction(args[1], args[2]);
        break;

      case "setSwapModule":
        if (!args[1] || !args[2]) {
          error("Usage: bun safe setSwapModule <chain> <moduleAddress>");
          process.exit(1);
        }
        await setSwapModule(args[1], args[2]);
        break;

      case "addPaymentToken":
        if (!args[1] || !args[2] || !args[3]) {
          error("Usage: bun safe addPaymentToken <chain> <token> <recipient>");
          process.exit(1);
        }
        await addPaymentToken(args[1], args[2], args[3]);
        break;

      case "removePaymentToken":
        if (!args[1] || !args[2]) {
          error("Usage: bun safe removePaymentToken <chain> <token>");
          process.exit(1);
        }
        await removePaymentToken(args[1], args[2]);
        break;

      case "sweep":
        if (!args[1] || !args[2] || !args[3] || !args[4]) {
          error("Usage: bun safe sweep <chain> <core|router> <token> <to>");
          process.exit(1);
        }
        if (args[2] !== "core" && args[2] !== "router") {
          error("Contract must be 'core' or 'router'");
          process.exit(1);
        }
        await sweep(args[1], args[2], args[3], args[4]);
        break;

      default:
        error(`Unknown command: ${command}`);
        printUsage();
        process.exit(1);
    }
  } catch (e) {
    error(e.message);
    if (process.env.DEBUG) {
      console.error(e);
    }
    process.exit(1);
  }
}

main();
