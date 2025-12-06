#!/usr/bin/env node

/**
 * Salt Generator - Generate CREATE3 salts for deterministic deployments
 *
 * Usage:
 *   bun salt                     Generate salt using deployer from config
 *   bun salt <address>           Generate salt for specific address
 *   bun salt --pair              Generate a pair of salts (core + router)
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const CONFIG_PATH = path.join(__dirname, "..", "config.json");
const ENV_PATH = path.join(__dirname, "..", ".env");

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
    return null;
  }
  return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
}

function isValidAddress(addr) {
  return typeof addr === "string" && /^0x[a-fA-F0-9]{40}$/.test(addr);
}

function generateSalt(deployerAddress) {
  // Salt format for CreateX cross-chain deployments:
  // - Bytes 0-19:  Deployer address (20 bytes)
  // - Byte 20:     0x00 for cross-chain (same address on all chains)
  // - Bytes 21-31: Entropy (11 bytes)
  // Total: 32 bytes (64 hex chars)
  const deployer = deployerAddress.toLowerCase().slice(2);
  const crossChainByte = "00";
  const entropy = crypto.randomBytes(11).toString("hex");
  return "0x" + deployer + crossChainByte + entropy;
}

function printUsage() {
  log("");
  log(`${colors.blue}Salt Generator${colors.reset} - Generate CREATE3 salts for deterministic deployments`);
  log("");
  log(`${colors.bold}Usage:${colors.reset}`);
  log("");
  log(`  ${colors.green}bun salt${colors.reset}`);
  log(`      Generate a single salt using deployer from config`);
  log("");
  log(`  ${colors.green}bun salt <address>${colors.reset}`);
  log(`      Generate a salt for a specific deployer address`);
  log("");
  log(`  ${colors.green}bun salt --pair${colors.reset}`);
  log(`      Generate a pair of salts (for core + router)`);
  log("");
  log(`  ${colors.green}bun salt --pair <address>${colors.reset}`);
  log(`      Generate a pair for a specific deployer address`);
  log("");
  log(`${colors.bold}Examples:${colors.reset}`);
  log(`  ${colors.dim}bun salt${colors.reset}`);
  log(`  ${colors.dim}bun salt 0xbadfaceB351045374d7fd1d3915e62501BA9916C${colors.reset}`);
  log(`  ${colors.dim}bun salt --pair${colors.reset}`);
  log("");
  log(`${colors.bold}Salt Format:${colors.reset}`);
  log(`  CreateX cross-chain salts are 32 bytes:`);
  log(`  ${colors.dim}<deployer:20 bytes><0x00:1 byte><entropy:11 bytes>${colors.reset}`);
  log(`  The 0x00 byte enables cross-chain deterministic addresses.`);
  log("");
}

function main() {
  const args = process.argv.slice(2);

  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    process.exit(0);
  }

  const isPair = args.includes("--pair") || args.includes("-p");
  const addressArg = args.find((a) => a.startsWith("0x"));

  let deployerAddress;

  if (addressArg) {
    if (!isValidAddress(addressArg)) {
      log(`${colors.red}✗${colors.reset} Invalid address: ${addressArg}`);
      process.exit(1);
    }
    deployerAddress = addressArg;
  } else {
    const envVars = loadEnv();
    const config = loadConfig();
    deployerAddress =
      process.env.DEPLOYER_ADDRESS ||
      envVars.DEPLOYER_ADDRESS ||
      config?.deployer?.address;

    if (!deployerAddress) {
      log(`${colors.red}✗${colors.reset} No deployer address found`);
      log("");
      log("  Provide an address or set one in config.json/env:");
      log(`  ${colors.dim}bun salt 0x...${colors.reset}`);
      process.exit(1);
    }

    if (!isValidAddress(deployerAddress)) {
      log(`${colors.red}✗${colors.reset} Invalid deployer address in config: ${deployerAddress}`);
      process.exit(1);
    }
  }

  log("");
  log(`${colors.blue}Salt Generator${colors.reset}`);
  log("─".repeat(50));
  log("");
  log(`  ${colors.bold}Deployer:${colors.reset} ${deployerAddress}`);
  log("");

  if (isPair) {
    const coreSalt = generateSalt(deployerAddress);
    const routerSalt = generateSalt(deployerAddress);

    log(`  ${colors.bold}Core Salt:${colors.reset}`);
    log(`  ${colors.green}${coreSalt}${colors.reset}`);
    log("");
    log(`  ${colors.bold}Router Salt:${colors.reset}`);
    log(`  ${colors.green}${routerSalt}${colors.reset}`);
    log("");
    log("─".repeat(50));
    log("");
    log(`${colors.bold}Add to config.json:${colors.reset}`);
    log("");
    log(`  "salts": {`);
    log(`    "core": "${coreSalt}",`);
    log(`    "router": "${routerSalt}"`);
    log(`  }`);
  } else {
    const salt = generateSalt(deployerAddress);

    log(`  ${colors.bold}Salt:${colors.reset}`);
    log(`  ${colors.green}${salt}${colors.reset}`);
  }

  log("");
}

main();
