/**
 * Environment loading - .env file loading with Zod validation
 */

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { z } from "zod";
import { AddressSchema, SaltSchema, OpRefSchema } from "./validation";

const SignerEnvSchema = z.object({
  name: z.string(),
  address: AddressSchema.optional(),
  keyRef: OpRefSchema,
});

export type SignerEnv = z.infer<typeof SignerEnvSchema>;

export const EnvSchema = z.object({
  RPC_KEY: z.string().min(1).optional(),
  ETHERSCAN_API_KEY: z.string().optional(),
  DEPLOYER_ADDRESS: AddressSchema.optional(),
  DEPLOYER_KEY_REF: OpRefSchema.optional(),
  SAFE_API_KEY: z.string().optional(),
});

export type Env = z.infer<typeof EnvSchema>;

export function loadContractSaltOverrides(envPath?: string): Record<string, string> {
  const raw = loadEnvRaw(envPath);
  const overrides: Record<string, string> = {};

  for (const [key, value] of Object.entries(raw)) {
    if (key.endsWith("_SALT") && value && SaltSchema.safeParse(value).success) {
      const contractName = key.slice(0, -5).toUpperCase();
      overrides[contractName] = value;
    }
  }

  for (const [key, value] of Object.entries(process.env)) {
    if (key.endsWith("_SALT") && value && SaltSchema.safeParse(value).success) {
      const contractName = key.slice(0, -5).toUpperCase();
      overrides[contractName] = value;
    }
  }

  return overrides;
}

function parseEnvFile(content: string): Record<string, string> {
  const env: Record<string, string> = {};
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

export function loadEnvRaw(envPath?: string): Record<string, string> {
  const resolvedPath = envPath ?? join(process.cwd(), ".env");
  if (!existsSync(resolvedPath)) {
    return {};
  }
  const content = readFileSync(resolvedPath, "utf8");
  return parseEnvFile(content);
}

export function loadEnv(envPath?: string): Env {
  const raw = loadEnvRaw(envPath);

  const envData: Record<string, string | undefined> = {
    RPC_KEY: process.env.RPC_KEY ?? raw.RPC_KEY,
    ETHERSCAN_API_KEY: process.env.ETHERSCAN_API_KEY ?? raw.ETHERSCAN_API_KEY,
    DEPLOYER_ADDRESS: process.env.DEPLOYER_ADDRESS ?? raw.DEPLOYER_ADDRESS,
    DEPLOYER_KEY_REF: process.env.DEPLOYER_KEY_REF ?? raw.DEPLOYER_KEY_REF,
    SAFE_API_KEY: process.env.SAFE_API_KEY ?? raw.SAFE_API_KEY,
  };

  const filtered: Record<string, string> = {};
  for (const [key, value] of Object.entries(envData)) {
    if (value !== undefined && value !== "") {
      filtered[key] = value;
    }
  }

  return EnvSchema.parse(filtered);
}

export function loadSigners(envPath?: string): SignerEnv[] {
  const raw = loadEnvRaw(envPath);
  const signers: SignerEnv[] = [];

  for (let i = 1; i <= 10; i++) {
    const name = raw[`SIGNER_${i}_NAME`];
    const address = raw[`SIGNER_${i}_ADDRESS`];
    const keyRef = raw[`SIGNER_${i}_KEY_REF`];

    if (name && keyRef) {
      const result = SignerEnvSchema.safeParse({
        name,
        address: address || undefined,
        keyRef,
      });

      if (result.success) {
        signers.push(result.data);
      }
    }
  }

  return signers;
}
