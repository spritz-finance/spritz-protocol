#!/usr/bin/env bun

/**
 * Salt Generator - Generate CREATE3 salts for deterministic deployments
 *
 * Usage:
 *   bun salt <ContractName>          Generate salt for a contract
 *   bun salt                         Generate a single salt
 *   bun salt --show <Contract>       Show current salt from config
 */

import { loadEnv } from "./lib/env";
import { loadConfig, loadConfigSafe, getContractConfig, getContractNames } from "./lib/config";
import { generateSalt, getContractAddress } from "./lib/createx";
import { isValidAddress } from "./lib/validation";
import { log, error, info, colors } from "./lib/console";

function printUsage(): void {
  log("");
  log(`${colors.blue}Salt Generator${colors.reset} - Generate CREATE3 salts for deterministic deployments`);
  log("");
  log(`${colors.bold}Usage:${colors.reset}`);
  log("");
  log(`  ${colors.green}bun salt <ContractName>${colors.reset}`);
  log(`      Generate a new salt for a contract (add to config.json)`);
  log("");
  log(`  ${colors.green}bun salt${colors.reset}`);
  log(`      Generate a single salt (generic)`);
  log("");
  log(`  ${colors.green}bun salt --show <ContractName>${colors.reset}`);
  log(`      Show current salt and address for a contract`);
  log("");
  log(`  ${colors.green}bun salt --show${colors.reset}`);
  log(`      Show all configured contracts with salts`);
  log("");
  log(`${colors.bold}Examples:${colors.reset}`);
  log(`  ${colors.dim}bun salt SpritzPayCore${colors.reset}`);
  log(`  ${colors.dim}bun salt ParaswapSwapModule${colors.reset}`);
  log(`  ${colors.dim}bun salt --show SpritzRouter${colors.reset}`);
  log("");
  log(`${colors.bold}Salt Format:${colors.reset}`);
  log(`  CreateX cross-chain salts are 32 bytes:`);
  log(`  ${colors.dim}<deployer:20 bytes><0x00:1 byte><entropy:11 bytes>${colors.reset}`);
  log(`  The 0x00 byte enables cross-chain deterministic addresses.`);
  log("");
}

function showContractSalt(contractName: string): void {
  const config = loadConfig();
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

  log("");
  log(`${colors.blue}${contractName}${colors.reset}`);
  log("─".repeat(50));
  log("");
  log(`  ${colors.bold}Salt:${colors.reset}`);
  log(`  ${colors.green}${contractConfig.salt}${colors.reset}`);
  log("");
  log(`  ${colors.bold}Computed Address:${colors.reset}`);
  log(`  ${address}`);
  log("");
  log(`  ${colors.bold}Deployer:${colors.reset} ${config.deployer.address}`);
  log("");
}

function showAllContracts(): void {
  const config = loadConfig();
  const contracts = getContractNames(config);

  log("");
  log(`${colors.blue}Configured Contracts${colors.reset}`);
  log("─".repeat(60));
  log("");

  for (const name of contracts) {
    const contractConfig = getContractConfig(config, name)!;
    const address = getContractAddress(config, name);
    const argsStr = contractConfig.args ? ` ${colors.dim}← ${contractConfig.args.join(", ")}${colors.reset}` : "";

    log(`  ${colors.bold}${name}${colors.reset}${argsStr}`);
    log(`    ${colors.dim}Salt: ${contractConfig.salt.slice(0, 22)}...${colors.reset}`);
    log(`    ${colors.dim}Addr: ${address}${colors.reset}`);
    log("");
  }
}

function generateContractSalt(contractName?: string): void {
  const env = loadEnv();
  const config = loadConfigSafe();

  const deployerAddress = env.DEPLOYER_ADDRESS ?? config?.deployer.address;

  if (!deployerAddress) {
    error("No deployer address found");
    log("");
    log("  Set deployer.address in config.json or DEPLOYER_ADDRESS in .env");
    process.exit(1);
  }

  if (!isValidAddress(deployerAddress)) {
    error(`Invalid deployer address: ${deployerAddress}`);
    process.exit(1);
  }

  const salt = generateSalt(deployerAddress);

  log("");
  log(`${colors.blue}Salt Generator${colors.reset}`);
  log("─".repeat(50));
  log("");
  log(`  ${colors.bold}Deployer:${colors.reset} ${deployerAddress}`);
  log("");

  if (contractName) {
    log(`  ${colors.bold}Contract:${colors.reset} ${contractName}`);
    log("");
    log(`  ${colors.bold}Salt:${colors.reset}`);
    log(`  ${colors.green}${salt}${colors.reset}`);
    log("");
    log("─".repeat(50));
    log("");
    log(`${colors.bold}Add to config.json contracts:${colors.reset}`);
    log("");
    log(`  "${contractName}": {`);
    log(`    "salt": "${salt}"`);
    log(`  }`);
  } else {
    log(`  ${colors.bold}Salt:${colors.reset}`);
    log(`  ${colors.green}${salt}${colors.reset}`);
  }

  log("");
}

function main(): void {
  const args = process.argv.slice(2);

  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    process.exit(0);
  }

  if (args[0] === "--show" || args[0] === "-s") {
    const contractName = args[1];
    if (contractName) {
      showContractSalt(contractName);
    } else {
      showAllContracts();
    }
    process.exit(0);
  }

  const contractName = args.find((a) => !a.startsWith("-") && !a.startsWith("0x"));

  generateContractSalt(contractName);
}

main();
