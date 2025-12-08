/**
 * CreateX utilities - CREATE3 address computation and salt generation
 */

import { execSync } from "child_process";
import { randomBytes } from "crypto";
import type { Config } from "./config";

export const CREATEX_ADDRESS = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed";

export function generateSalt(deployerAddress: string): string {
  const deployer = deployerAddress.toLowerCase().slice(2);
  const crossChainByte = "00";
  const entropy = randomBytes(11).toString("hex");
  return "0x" + deployer + crossChainByte + entropy;
}

export function computeCreate3Address(deployer: string, salt: string): string {
  const deployerPadded = deployer.toLowerCase().slice(2).padStart(64, "0");
  const saltHex = salt.slice(2);
  const guardedSalt = execSync(`cast keccak 0x${deployerPadded}${saltHex}`, {
    encoding: "utf8",
  }).trim();

  const proxyInitCodeHash =
    "0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f";

  const factoryHex = CREATEX_ADDRESS.toLowerCase().slice(2);
  const guardedSaltHex = guardedSalt.slice(2);
  const proxyInputHex = `ff${factoryHex}${guardedSaltHex}${proxyInitCodeHash.slice(2)}`;
  const proxyHash = execSync(`cast keccak 0x${proxyInputHex}`, {
    encoding: "utf8",
  }).trim();
  const proxyAddress = "0x" + proxyHash.slice(-40);

  const deployedInputHex = `d694${proxyAddress.slice(2)}01`;
  const deployedHash = execSync(`cast keccak 0x${deployedInputHex}`, {
    encoding: "utf8",
  }).trim();
  const deployedAddress = "0x" + deployedHash.slice(-40);

  return deployedAddress;
}

export function checksumAddress(address: string): string {
  return execSync(`cast to-check-sum-address ${address}`, {
    encoding: "utf8",
  }).trim();
}

export function getContractAddress(config: Config, contractName: string): string | null {
  const contractConfig = config.contracts[contractName];
  if (!contractConfig) {
    return null;
  }

  const address = computeCreate3Address(config.deployer.address, contractConfig.salt);
  return checksumAddress(address);
}

/**
 * Resolves constructor arguments for a contract.
 *
 * Supports three types of arguments:
 * 1. Contract references: "SpritzPayCore" -> resolved to deployed address
 * 2. Chain-specific references: "${chain.weth}" -> resolved from chain config
 * 3. Literal values: "0x123..." -> passed through unchanged
 *
 * @param config - The deployment config
 * @param contractName - Name of the contract to resolve args for
 * @param chainName - Optional chain name for resolving chain-specific references
 * @returns Array of resolved constructor argument values
 */
export function resolveConstructorArgs(
  config: Config,
  contractName: string,
  chainName?: string
): string[] {
  const contractConfig = config.contracts[contractName];
  if (!contractConfig?.args) {
    return [];
  }

  return contractConfig.args.map((arg) => {
    // Check if it's a chain-specific reference: ${chain.weth}
    const chainMatch = arg.match(/^\$\{chain\.(\w+)\}$/);
    if (chainMatch) {
      const addressKey = chainMatch[1];
      if (!chainName) {
        throw new Error(
          `Cannot resolve chain-specific arg "${arg}" without chain name. ` +
          `Contract ${contractName} requires chain context.`
        );
      }
      const chainConfig = config.chains[chainName];
      if (!chainConfig) {
        throw new Error(`Unknown chain: ${chainName}`);
      }
      const address = chainConfig.addresses?.[addressKey];
      if (!address) {
        throw new Error(
          `Chain "${chainName}" does not have address "${addressKey}" configured. ` +
          `Add it to chains.${chainName}.addresses.${addressKey} in config.json`
        );
      }
      return address;
    }

    // Check if it's a contract reference
    if (config.contracts[arg]) {
      const address = getContractAddress(config, arg);
      if (!address) {
        throw new Error(`Cannot resolve address for dependency: ${arg}`);
      }
      return address;
    }

    // Literal value - pass through unchanged
    return arg;
  });
}

/**
 * Checks if a contract has chain-specific constructor arguments.
 * These contracts will have different constructor args per chain.
 */
export function hasChainSpecificArgs(config: Config, contractName: string): boolean {
  const contractConfig = config.contracts[contractName];
  if (!contractConfig?.args) {
    return false;
  }
  return contractConfig.args.some((arg) => arg.startsWith("${chain."));
}

export function getContractDependencies(config: Config, contractName: string): string[] {
  const contractConfig = config.contracts[contractName];
  if (!contractConfig?.args) {
    return [];
  }

  return contractConfig.args.filter((arg) => config.contracts[arg] !== undefined);
}

export function getDeploymentOrder(config: Config): string[] {
  const contracts = Object.keys(config.contracts);
  const visited = new Set<string>();
  const order: string[] = [];

  function visit(name: string): void {
    if (visited.has(name)) return;
    visited.add(name);

    const deps = getContractDependencies(config, name);
    for (const dep of deps) {
      visit(dep);
    }

    order.push(name);
  }

  for (const contract of contracts) {
    visit(contract);
  }

  return order;
}
