/**
 * Config loading - config.json loading with Zod schemas
 */

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { z } from "zod";
import { AddressSchema, SaltSchema, OpRefSchema, getDeployerFromSalt } from "./validation";

const ChainConfigSchema = z.object({
  chainId: z.number(),
  rpc: z.string(),
  explorer: z.string().url(),
  etherscanApi: z.string().url().optional(),
  safeService: z.string().url().optional(),
  testnet: z.boolean().optional(),
  // Chain-specific addresses for contracts with chain-dependent constructor args
  addresses: z.record(z.string(), AddressSchema).optional(),
});

const ContractConfigSchema = z.object({
  salt: SaltSchema,
  args: z.array(z.string()).optional(),
});

const EnvironmentConfigSchema = z.object({
  contracts: z.record(z.string(), ContractConfigSchema.partial()),
});

export const ConfigSchema = z.object({
  admin: z.object({
    safe: AddressSchema,
    threshold: z.number().min(1),
  }),
  deployer: z.object({
    address: AddressSchema,
    keyRef: OpRefSchema,
  }),
  contracts: z.record(z.string(), ContractConfigSchema),
  environments: z.record(z.string(), EnvironmentConfigSchema).optional(),
  etherscan: z
    .object({
      apiKey: z.string(),
    })
    .optional(),
  chains: z.record(z.string(), ChainConfigSchema),
});

export type Environment = "production" | "sandbox";

export type Config = z.infer<typeof ConfigSchema>;
export type ChainConfig = z.infer<typeof ChainConfigSchema>;
export type ContractConfig = z.infer<typeof ContractConfigSchema>;

export interface LoadConfigOptions {
  configPath?: string;
  environment?: Environment;
}

export function loadConfig(options?: LoadConfigOptions): Config {
  const resolvedPath = options?.configPath ?? join(process.cwd(), "config.json");
  const environment = options?.environment ?? "production";

  if (!existsSync(resolvedPath)) {
    throw new Error(`config.json not found at ${resolvedPath}. Run from project root.`);
  }

  const content = readFileSync(resolvedPath, "utf8");
  const raw = JSON.parse(content);
  const config = ConfigSchema.parse(raw);

  // For production, use contracts as-is
  if (environment === "production") {
    return config;
  }

  // For other environments, merge environment-specific contract overrides
  const envConfig = config.environments?.[environment];
  if (!envConfig) {
    throw new Error(`Environment "${environment}" not found in config.json`);
  }

  const mergedContracts = { ...config.contracts };
  for (const [name, overrides] of Object.entries(envConfig.contracts)) {
    if (mergedContracts[name]) {
      mergedContracts[name] = {
        ...mergedContracts[name],
        ...overrides,
      };
    }
  }

  return {
    ...config,
    contracts: mergedContracts,
  };
}

export function loadConfigSafe(options?: LoadConfigOptions): Config | null {
  try {
    return loadConfig(options);
  } catch {
    return null;
  }
}

export function getContractConfig(config: Config, contractName: string): ContractConfig | null {
  return config.contracts[contractName] ?? null;
}

export function parseEnvironmentArg(args: string[]): Environment {
  const envIndex = args.findIndex((a) => a === "--env" || a === "-e");
  if (envIndex === -1 || envIndex === args.length - 1) {
    return "production";
  }
  const envValue = args[envIndex + 1];
  if (envValue !== "production" && envValue !== "sandbox") {
    throw new Error(`Invalid environment: ${envValue}. Must be "production" or "sandbox"`);
  }
  return envValue;
}

export function filterEnvArg(args: string[]): string[] {
  const result: string[] = [];
  let i = 0;
  while (i < args.length) {
    if (args[i] === "--env" || args[i] === "-e") {
      i += 2; // Skip --env and its value
    } else {
      result.push(args[i]);
      i++;
    }
  }
  return result;
}

export function getContractNames(config: Config): string[] {
  return Object.keys(config.contracts);
}

export interface EnvOverrides {
  DEPLOYER_ADDRESS?: string;
  DEPLOYER_KEY_REF?: string;
  contractSalts?: Record<string, string>;
}

export interface ApplyEnvResult {
  config: Config;
  warnings: string[];
}

export function applyEnvOverrides(config: Config, env: EnvOverrides): ApplyEnvResult {
  const warnings: string[] = [];
  const newDeployer = env.DEPLOYER_ADDRESS ?? config.deployer.address;

  const newContracts = { ...config.contracts };
  const saltOverrides = env.contractSalts ?? {};

  for (const configContractName of Object.keys(newContracts)) {
    const upperName = configContractName.toUpperCase();
    if (saltOverrides[upperName]) {
      newContracts[configContractName] = {
        ...newContracts[configContractName],
        salt: saltOverrides[upperName],
      };
    }
  }

  for (const [contractName, contractConfig] of Object.entries(newContracts)) {
    const saltDeployer = getDeployerFromSalt(contractConfig.salt);
    if (saltDeployer.toLowerCase() !== newDeployer.toLowerCase()) {
      warnings.push(
        `${contractName}: salt deployer (${saltDeployer.slice(0, 10)}...) doesn't match deployer (${newDeployer.slice(0, 10)}...). ` +
        `CreateX will reject this deployment.`
      );
    }
  }

  return {
    config: {
      ...config,
      deployer: {
        address: newDeployer,
        keyRef: env.DEPLOYER_KEY_REF ?? config.deployer.keyRef,
      },
      contracts: newContracts,
    },
    warnings,
  };
}
