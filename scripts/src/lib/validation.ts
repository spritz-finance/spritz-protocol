/**
 * Validation utilities - shared validation helpers
 */

import { z } from "zod";

export const AddressSchema = z
  .string()
  .regex(/^0x[a-fA-F0-9]{40}$/, "Invalid Ethereum address");

export const SaltSchema = z
  .string()
  .regex(/^0x[a-fA-F0-9]{64}$/, "Invalid salt (must be 0x + 64 hex chars)");

export const OpRefSchema = z
  .string()
  .startsWith("op://", "1Password reference must start with op://")
  .min(10, "1Password reference too short");

export type Address = z.infer<typeof AddressSchema>;
export type Salt = z.infer<typeof SaltSchema>;
export type OpRef = z.infer<typeof OpRefSchema>;

export function isValidAddress(addr: string): addr is Address {
  return AddressSchema.safeParse(addr).success;
}

export function isValidSalt(salt: string): salt is Salt {
  return SaltSchema.safeParse(salt).success;
}

export function isValid1PasswordRef(ref: string): ref is OpRef {
  return OpRefSchema.safeParse(ref).success;
}

export function getDeployerFromSalt(salt: string): string {
  return "0x" + salt.slice(2, 42);
}

export function validateDeployerMatchesSalt(
  deployerAddress: string,
  salt: string
): boolean {
  const saltDeployer = getDeployerFromSalt(salt);
  return deployerAddress.toLowerCase() === saltDeployer.toLowerCase();
}
