#!/usr/bin/env bun

/**
 * Deploy Script - Deploys frozen contracts via CreateX with 1Password integration
 *
 * Usage:
 *   bun deployment <Contract> <chain>              Simulate deployment
 *   bun deployment <Contract> <chain> --broadcast  Deploy for real
 *   bun deployment --address <Contract>            Show computed address
 *   bun deployment --list                          List configured contracts
 *   bun deployment --chains                        List available chains
 */

import { execSync, spawnSync } from "child_process";
import { randomUUID } from "crypto";
import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { buildChains, listChainNames, type Chain } from "./lib/chains";
import {
  applyEnvOverrides,
  getContractConfig,
  getContractNames,
  loadConfig,
  type Config,
} from "./lib/config";
import { colors, error, info, log, success, warn } from "./lib/console";
import {
  getContractAddress,
  getContractDependencies,
  getDeploymentOrder,
  resolveConstructorArgs,
} from "./lib/createx";
import { loadContractSaltOverrides, loadEnv, type Env } from "./lib/env";
import { checkOpCli, checkOpSignedIn, getAddressFromKey } from "./lib/op";

const DEPLOYMENTS_DIR = join(process.cwd(), "deployments");

interface DeploymentRecord {
  id: string;
  deployer: string;
  address: string;
  salt: string;
  chains: string[];
}

interface Metadata {
  contract: string;
  initcodeHash: string;
  deployments: DeploymentRecord[];
}

function getDeploymentMetadata(contractName: string): Metadata | null {
  const metadataPath = join(DEPLOYMENTS_DIR, contractName, "metadata.json");
  if (!existsSync(metadataPath)) {
    return null;
  }
  return JSON.parse(readFileSync(metadataPath, "utf8"));
}

function getFrozenInitcode(contractName: string): string | null {
  const initcodePath = join(
    DEPLOYMENTS_DIR,
    contractName,
    "artifacts",
    `${contractName}.initcode`,
  );
  if (!existsSync(initcodePath)) {
    return null;
  }
  return readFileSync(initcodePath, "utf8").trim();
}

function getFrozenDeployedBytecode(contractName: string): string | null {
  const deployedPath = join(
    DEPLOYMENTS_DIR,
    contractName,
    "artifacts",
    `${contractName}.deployed`,
  );
  if (!existsSync(deployedPath)) {
    return null;
  }
  return readFileSync(deployedPath, "utf8").trim();
}

function verifyFrozenBytecode(contractName: string): {
  valid: boolean;
  error?: string;
  initcodeHash?: string;
} {
  const metadata = getDeploymentMetadata(contractName);
  if (!metadata) {
    return {
      valid: false,
      error: "No frozen bytecode found. Run: bun freeze " + contractName,
    };
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

function checkAlreadyDeployed(chain: Chain, address: string): boolean {
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

function verifyDeployedBytecode(
  chain: Chain,
  address: string,
  contractName: string,
): { valid: boolean; error?: string } {
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
        error: "On-chain bytecode differs from frozen (may have immutables)",
      };
    }

    return { valid: true };
  } catch (e) {
    return { valid: false, error: (e as Error).message };
  }
}

function checkRpcHealth(chain: Chain): {
  healthy: boolean;
  blockNumber?: number;
  error?: string;
} {
  try {
    const blockNumber = execSync(`cast block-number --rpc-url ${chain.rpc}`, {
      encoding: "utf8",
      timeout: 10000,
    }).trim();
    return { healthy: true, blockNumber: parseInt(blockNumber) };
  } catch (e) {
    return { healthy: false, error: (e as Error).message };
  }
}

function verifyDeployerAddress(
  deployerKeyRef: string,
  expectedAddress: string,
): { valid: boolean; address?: string } {
  info("Verifying deployer address matches 1Password key...");

  const deployerFromKey = getAddressFromKey(deployerKeyRef);
  if (!deployerFromKey) {
    error("Failed to get deployer address from 1Password");
    return { valid: false };
  }

  if (deployerFromKey.toLowerCase() !== expectedAddress.toLowerCase()) {
    error(`Deployer address mismatch!`);
    log("");
    log(`  Config expects: ${colors.green}${expectedAddress}${colors.reset}`);
    log(`  1Password key:  ${colors.red}${deployerFromKey}${colors.reset}`);
    log("");
    return { valid: false };
  }

  success(`Deployer verified: ${deployerFromKey}`);
  return { valid: true, address: deployerFromKey };
}

function addDeploymentRecord(
  contractName: string,
  deployer: string,
  address: string,
  salt: string,
  chainName: string,
): boolean {
  const metadataPath = join(DEPLOYMENTS_DIR, contractName, "metadata.json");
  const metadata = getDeploymentMetadata(contractName);
  if (!metadata) {
    error(`No metadata found for ${contractName}`);
    return false;
  }

  if (!metadata.deployments) {
    metadata.deployments = [];
  }

  let deployment = metadata.deployments.find(
    (d) => d.salt.toLowerCase() === salt.toLowerCase(),
  );

  if (deployment) {
    if (!deployment.chains.includes(chainName)) {
      deployment.chains.push(chainName);
    }
  } else {
    const id = randomUUID();
    metadata.deployments.push({
      id,
      deployer,
      address,
      salt,
      chains: [chainName],
    });
  }

  writeFileSync(metadataPath, JSON.stringify(metadata, null, 2));
  return true;
}

function showContractAddress(config: Config, contractName: string): void {
  const contractConfig = getContractConfig(config, contractName);
  if (!contractConfig) {
    error(`Contract not configured: ${contractName}`);
    log("");
    log("Configured contracts:");
    for (const name of getContractNames(config)) {
      log(`  - ${name}`);
    }
    process.exit(1);
  }

  const address = getContractAddress(config, contractName);
  const deps = getContractDependencies(config, contractName);
  const args = resolveConstructorArgs(config, contractName);

  log("");
  log(`${colors.blue}${contractName}${colors.reset}`);
  log("─".repeat(50));
  log("");
  log(`  ${colors.bold}Address:${colors.reset}  ${address}`);
  log(
    `  ${colors.bold}Salt:${colors.reset}     ${colors.dim}${contractConfig.salt.slice(0, 22)}...${colors.reset}`,
  );
  log(`  ${colors.bold}Deployer:${colors.reset} ${config.deployer.address}`);

  if (deps.length > 0) {
    log("");
    log(`  ${colors.bold}Dependencies:${colors.reset}`);
    for (let i = 0; i < deps.length; i++) {
      const depAddress = getContractAddress(config, deps[i]);
      log(`    ${deps[i]} → ${depAddress}`);
    }
  }

  if (args.length > 0) {
    log("");
    log(`  ${colors.bold}Constructor Args:${colors.reset}`);
    for (const arg of args) {
      log(`    ${arg}`);
    }
  }

  log("");
}

function listContracts(config: Config): void {
  const order = getDeploymentOrder(config);

  log("");
  log(`${colors.blue}Configured Contracts${colors.reset}`);
  log("─".repeat(60));
  log("");

  for (const name of order) {
    const address = getContractAddress(config, name);
    const deps = getContractDependencies(config, name);
    const metadata = getDeploymentMetadata(name);
    const frozen = metadata !== null;
    const deployedChains =
      metadata?.deployments?.flatMap((d) => d.chains) ?? [];

    const frozenIcon = frozen
      ? `${colors.green}✓${colors.reset}`
      : `${colors.dim}○${colors.reset}`;
    const depsStr =
      deps.length > 0
        ? ` ${colors.dim}← ${deps.join(", ")}${colors.reset}`
        : "";
    const chainsStr =
      deployedChains.length > 0
        ? ` ${colors.dim}[${deployedChains.join(", ")}]${colors.reset}`
        : "";

    log(`  ${frozenIcon} ${colors.bold}${name}${colors.reset}${depsStr}`);
    log(`    ${colors.dim}${address}${colors.reset}${chainsStr}`);
    log("");
  }
}

function listChains(chains: Record<string, Chain>): void {
  log("");
  log(`${colors.blue}Available Chains${colors.reset}`);
  log("─".repeat(50));

  const { mainnets, testnets } = listChainNames(chains);

  log("");
  log(`${colors.bold}Mainnets${colors.reset}`);
  for (const name of mainnets) {
    const chain = chains[name];
    log(
      `  ${colors.green}${name.padEnd(15)}${colors.reset} ${colors.dim}${chain.explorer}${colors.reset}`,
    );
  }

  log("");
  log(`${colors.bold}Testnets${colors.reset}`);
  for (const name of testnets) {
    const chain = chains[name];
    log(
      `  ${colors.yellow}${name.padEnd(15)}${colors.reset} ${colors.dim}${chain.explorer}${colors.reset}`,
    );
  }

  log("");
}

function runPreflightChecks(
  config: Config,
  contractName: string,
  chain: Chain,
  chainName: string,
): { passed: boolean; alreadyDeployed: boolean; address: string } {
  log("");
  log(`${colors.bold}Pre-flight Checks${colors.reset}`);
  log("─".repeat(50));
  log("");

  let allPassed = true;

  info(`Verifying frozen bytecode for ${contractName}...`);
  const bytecodeResult = verifyFrozenBytecode(contractName);
  if (!bytecodeResult.valid) {
    error(bytecodeResult.error!);
    allPassed = false;
  } else {
    success(`${contractName} frozen bytecode verified`);
  }

  const deps = getContractDependencies(config, contractName);
  if (deps.length > 0) {
    log("");
    info("Checking dependencies...");
    for (const dep of deps) {
      const depAddress = getContractAddress(config, dep);
      if (!depAddress) {
        error(`Dependency ${dep} not configured`);
        allPassed = false;
        continue;
      }

      const depDeployed = checkAlreadyDeployed(chain, depAddress);
      if (depDeployed) {
        success(`${dep} deployed at ${depAddress}`);
      } else {
        error(`${dep} not deployed at ${depAddress} on ${chainName}`);
        log(
          `    Deploy it first: ${colors.dim}bun deployment ${dep} ${chainName}${colors.reset}`,
        );
        allPassed = false;
      }
    }
  }

  log("");
  info(`Testing RPC connection to ${chainName}...`);
  const rpcResult = checkRpcHealth(chain);
  if (!rpcResult.healthy) {
    error(`RPC unreachable: ${rpcResult.error}`);
    allPassed = false;
  } else {
    success(`RPC healthy (block ${rpcResult.blockNumber})`);
  }

  log("");
  info("Computing deterministic address...");
  const address = getContractAddress(config, contractName)!;
  log(`  ${contractName}: ${address}`);

  log("");
  info("Checking if contract already deployed...");
  const alreadyDeployed = checkAlreadyDeployed(chain, address);
  if (alreadyDeployed) {
    warn(`${contractName} already deployed at ${address}`);
  } else {
    success("Address available for deployment");
  }

  return { passed: allPassed, alreadyDeployed, address };
}

function showDeploymentPlan(
  config: Config,
  contractName: string,
  chain: Chain,
  chainName: string,
  address: string,
): void {
  const contractConfig = getContractConfig(config, contractName)!;
  const metadata = getDeploymentMetadata(contractName);
  const args = resolveConstructorArgs(config, contractName);

  log("");
  log(
    `${colors.blue}═══════════════════════════════════════════════════════════${colors.reset}`,
  );
  log(`${colors.blue}  Deployment Plan: ${contractName}${colors.reset}`);
  log(
    `${colors.blue}═══════════════════════════════════════════════════════════${colors.reset}`,
  );
  log("");
  log(
    `  ${colors.bold}Chain:${colors.reset}       ${chainName} ${chain.testnet ? "(testnet)" : colors.yellow + "(MAINNET)" + colors.reset}`,
  );
  log(`  ${colors.bold}Chain ID:${colors.reset}    ${chain.chainId}`);
  log(`  ${colors.bold}Explorer:${colors.reset}    ${chain.explorer}`);
  log("");
  log(`  ${colors.bold}Deployer:${colors.reset}    ${config.deployer.address}`);
  log(`  ${colors.bold}Admin:${colors.reset}       ${config.admin.safe}`);
  log("");
  log(`  ${colors.bold}Contract:${colors.reset}    ${contractName}`);
  log(`  ${colors.bold}Address:${colors.reset}     ${address}`);
  log(
    `  ${colors.dim}Salt: ${contractConfig.salt.slice(0, 22)}...${colors.reset}`,
  );
  log(
    `  ${colors.dim}Initcode hash: ${metadata?.initcodeHash?.slice(0, 22)}...${colors.reset}`,
  );

  if (args.length > 0) {
    log("");
    log(`  ${colors.bold}Constructor Args:${colors.reset}`);
    for (const arg of args) {
      log(`    ${arg}`);
    }
  }

  log("");
}

function deploy(
  config: Config,
  env: Env,
  chains: Record<string, Chain>,
  contractName: string,
  chainName: string,
  broadcast: boolean = false,
): void {
  const chain = chains[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    log("");
    log(
      `Run ${colors.dim}bun deployment --chains${colors.reset} to see available chains`,
    );
    process.exit(1);
  }

  const contractConfig = getContractConfig(config, contractName);
  if (!contractConfig) {
    error(`Contract not configured: ${contractName}`);
    log("");
    log(
      `Run ${colors.dim}bun deployment --list${colors.reset} to see configured contracts`,
    );
    process.exit(1);
  }

  const preflight = runPreflightChecks(config, contractName, chain, chainName);

  if (!preflight.passed) {
    log("");
    error("Pre-flight checks failed. Aborting deployment.");
    process.exit(1);
  }

  showDeploymentPlan(config, contractName, chain, chainName, preflight.address);

  if (preflight.alreadyDeployed) {
    log(
      `${colors.green}Contract already deployed at expected address.${colors.reset}`,
    );
    log("");
    log(
      `To record this deployment: ${colors.dim}bun deployment --record ${contractName} ${chainName}${colors.reset}`,
    );
    log("");
    process.exit(0);
  }

  if (!broadcast) {
    log(`${colors.yellow}─── Simulation Mode ───${colors.reset}`);
    log("");
    info("To deploy for real, add --broadcast flag");
    log(
      `  ${colors.dim}bun deployment ${contractName} ${chainName} --broadcast${colors.reset}`,
    );
    log("");
    process.exit(0);
  }

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

  const verifyResult = verifyDeployerAddress(
    config.deployer.keyRef,
    config.deployer.address,
  );
  if (!verifyResult.valid) {
    process.exit(1);
  }

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

  info("Broadcasting deployment transaction...");
  log("");

  const args = resolveConstructorArgs(config, contractName);
  const constructorArgsEnv = args.length > 0 ? args.join(",") : "";

  const envVars = {
    ...process.env,
    ADMIN_ADDRESS: config.admin.safe,
    CONTRACT_NAME: contractName,
    CONTRACT_SALT: contractConfig.salt,
    CONSTRUCTOR_ARGS: constructorArgsEnv,
  };

  const forgeCmd = `forge script script/DeploySingle.s.sol:DeploySingle --rpc-url ${chain.rpc} --broadcast --private-key $(op read "${config.deployer.keyRef}")`;
  const result = spawnSync("sh", ["-c", forgeCmd], {
    stdio: "inherit",
    env: envVars,
    cwd: process.cwd(),
  });

  if (result.status !== 0) {
    log("");
    error("Deployment failed");
    process.exit(1);
  }

  log("");
  success("Deployment transaction broadcast!");

  log("");
  info("Verifying deployed bytecode...");

  execSync("sleep 3");

  const bytecodeVerify = verifyDeployedBytecode(
    chain,
    preflight.address,
    contractName,
  );
  if (!bytecodeVerify.valid) {
    const deps = getContractDependencies(config, contractName);
    if (deps.length > 0) {
      warn(
        `${contractName} bytecode differs (expected: has immutable dependencies)`,
      );
    } else {
      error(
        `${contractName} bytecode verification failed: ${bytecodeVerify.error}`,
      );
    }
  } else {
    success(`${contractName} bytecode matches frozen bytecode`);
  }

  log("");
  info("Recording deployment...");
  addDeploymentRecord(
    contractName,
    config.deployer.address,
    preflight.address,
    contractConfig.salt,
    chainName,
  );
  success("Deployment recorded");

  log("");
  log(
    `${colors.green}═══════════════════════════════════════════════════════════${colors.reset}`,
  );
  log(
    `${colors.green}  ${contractName} deployed to ${chainName}!${colors.reset}`,
  );
  log(
    `${colors.green}═══════════════════════════════════════════════════════════${colors.reset}`,
  );
  log("");
  log(`${colors.bold}Address:${colors.reset} ${preflight.address}`);
  log("");
  log(`${colors.bold}Next steps:${colors.reset}`);
  log(
    `  Verify: ${colors.dim}bun deployment --verify ${contractName} ${chainName}${colors.reset}`,
  );
  log("");
}

function recordDeployment(
  config: Config,
  chains: Record<string, Chain>,
  contractName: string,
  chainName: string,
): void {
  const chain = chains[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    process.exit(1);
  }

  const contractConfig = getContractConfig(config, contractName);
  if (!contractConfig) {
    error(`Contract not configured: ${contractName}`);
    process.exit(1);
  }

  log("");
  info(`Recording ${contractName} deployment on ${chainName}...`);

  const address = getContractAddress(config, contractName)!;

  info("Verifying contract exists on-chain...");
  const deployed = checkAlreadyDeployed(chain, address);
  if (!deployed) {
    error(`${contractName} not deployed at ${address} on ${chainName}`);
    process.exit(1);
  }
  success("Contract found on-chain");

  addDeploymentRecord(
    contractName,
    config.deployer.address,
    address,
    contractConfig.salt,
    chainName,
  );
  success(`Recorded ${contractName} at ${address} on ${chainName}`);
  log("");
}

function verifyContract(
  config: Config,
  env: Env,
  chains: Record<string, Chain>,
  contractName: string,
  chainName: string,
): void {
  const chain = chains[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    process.exit(1);
  }

  const contractConfig = getContractConfig(config, contractName);
  if (!contractConfig) {
    error(`Contract not configured: ${contractName}`);
    process.exit(1);
  }

  const address = getContractAddress(config, contractName)!;
  const args = resolveConstructorArgs(config, contractName);
  const etherscanApiKey = env.ETHERSCAN_API_KEY;

  log("");
  info(`Verifying ${contractName} at ${address} on ${chainName}...`);
  log("");

  let constructorArgsCmd = "";
  if (args.length > 0) {
    const types = args.map(() => "address").join(",");
    const values = args.join(" ");
    constructorArgsCmd = `--constructor-args $(cast abi-encode "constructor(${types})" ${values})`;
  }

  let verifierArgs = "";
  if (chain.etherscanApi && etherscanApiKey) {
    verifierArgs = `--verifier etherscan --verifier-url ${chain.etherscanApi} --etherscan-api-key ${etherscanApiKey}`;
  }

  const cmd = `forge verify-contract ${address} ${contractName} --chain ${chain.chainId} --watch ${constructorArgsCmd} ${verifierArgs}`;

  try {
    execSync(cmd, { stdio: "inherit", cwd: process.cwd() });
    success(`${contractName} verified on ${chainName}`);
  } catch {
    error(`Failed to verify ${contractName}`);
    process.exit(1);
  }
}

function printUsage(): void {
  log("");
  log(
    `${colors.blue}Deploy Script${colors.reset} - Deploy Spritz contracts with 1Password`,
  );
  log("");
  log(`${colors.bold}Commands:${colors.reset}`);
  log("");
  log(`  ${colors.green}bun deployment <Contract> <chain>${colors.reset}`);
  log(`      Run pre-flight checks (simulation, no tx)`);
  log("");
  log(
    `  ${colors.green}bun deployment <Contract> <chain> --broadcast${colors.reset}`,
  );
  log(`      Deploy contract to chain (requires 1Password)`);
  log("");
  log(`  ${colors.green}bun deployment --address <Contract>${colors.reset}`);
  log(`      Show computed address for a contract`);
  log("");
  log(`  ${colors.green}bun deployment --list${colors.reset}`);
  log(`      List all configured contracts`);
  log("");
  log(`  ${colors.green}bun deployment --chains${colors.reset}`);
  log(`      List all supported chains`);
  log("");
  log(
    `  ${colors.green}bun deployment --record <Contract> <chain>${colors.reset}`,
  );
  log(`      Record an existing deployment`);
  log("");
  log(
    `  ${colors.green}bun deployment --verify <Contract> <chain>${colors.reset}`,
  );
  log(`      Verify contract on block explorer`);
  log("");
  log(`${colors.bold}Examples:${colors.reset}`);
  log(
    `  ${colors.dim}bun deployment SpritzPayCore base${colors.reset}              # Simulate`,
  );
  log(
    `  ${colors.dim}bun deployment SpritzPayCore base --broadcast${colors.reset}  # Deploy`,
  );
  log(
    `  ${colors.dim}bun deployment SpritzRouter base --broadcast${colors.reset}   # Deploy (auto-resolves Core)`,
  );
  log(
    `  ${colors.dim}bun deployment --address SpritzRouter${colors.reset}          # Show address`,
  );
  log(
    `  ${colors.dim}bun deployment --verify SpritzPayCore base${colors.reset}     # Verify`,
  );
  log("");
  log(`${colors.bold}Workflow:${colors.reset}`);
  log(`  1. Freeze:  ${colors.dim}bun freeze SpritzPayCore${colors.reset}`);
  log(
    `  2. Salt:    ${colors.dim}bun salt SpritzPayCore${colors.reset}  (add to config.json)`,
  );
  log(
    `  3. Deploy:  ${colors.dim}bun deployment SpritzPayCore base --broadcast${colors.reset}`,
  );
  log(
    `  4. Verify:  ${colors.dim}bun deployment --verify SpritzPayCore base${colors.reset}`,
  );
  log("");
}

function main(): void {
  const args = process.argv.slice(2);

  const env = loadEnv();
  const saltOverrides = loadContractSaltOverrides();
  const baseConfig = loadConfig();
  const { config, warnings } = applyEnvOverrides(baseConfig, {
    DEPLOYER_ADDRESS: env.DEPLOYER_ADDRESS,
    DEPLOYER_KEY_REF: env.DEPLOYER_KEY_REF,
    contractSalts: saltOverrides,
  });

  for (const warning of warnings) {
    warn(warning);
  }

  const chains = buildChains(config, env.RPC_KEY ?? "");

  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") {
    printUsage();
    process.exit(0);
  }

  if (args[0] === "--list" || args[0] === "-l") {
    listContracts(config);
    process.exit(0);
  }

  if (args[0] === "--chains") {
    listChains(chains);
    process.exit(0);
  }

  if (args[0] === "--address" || args[0] === "-a") {
    const contractName = args[1];
    if (!contractName) {
      error("Missing contract name");
      log(`  Usage: bun deployment --address <Contract>`);
      process.exit(1);
    }
    showContractAddress(config, contractName);
    process.exit(0);
  }

  if (args[0] === "--record" || args[0] === "-r") {
    const contractName = args[1];
    const chainName = args[2];
    if (!contractName || !chainName) {
      error("Missing contract name or chain");
      log(`  Usage: bun deployment --record <Contract> <chain>`);
      process.exit(1);
    }
    recordDeployment(config, chains, contractName, chainName);
    process.exit(0);
  }

  if (args[0] === "--verify" || args[0] === "-v") {
    const contractName = args[1];
    const chainName = args[2];
    if (!contractName || !chainName) {
      error("Missing contract name or chain");
      log(`  Usage: bun deployment --verify <Contract> <chain>`);
      process.exit(1);
    }
    verifyContract(config, env, chains, contractName, chainName);
    process.exit(0);
  }

  if (args[0].startsWith("-")) {
    error(`Unknown option: ${args[0]}`);
    printUsage();
    process.exit(1);
  }

  const contractName = args[0];
  const chainName = args[1];

  if (!chainName) {
    error("Missing chain name");
    log(`  Usage: bun deployment <Contract> <chain>`);
    process.exit(1);
  }

  const broadcast = args.includes("--broadcast") || args.includes("-b");

  deploy(config, env, chains, contractName, chainName, broadcast);
}

main();
