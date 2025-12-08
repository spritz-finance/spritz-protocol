/**
 * 1Password CLI helpers - check, signin, read secrets
 */

import { execSync } from "child_process";

export function checkOpCli(): boolean {
  try {
    execSync("op --version", { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

export function checkOpSignedIn(): boolean {
  try {
    execSync("op account get", { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

export function readSecret(ref: string): string | null {
  try {
    return execSync(`op read "${ref}"`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return null;
  }
}

export function getAddressFromKey(keyRef: string): string | null {
  try {
    const cmd = `op read "${keyRef}" | xargs cast wallet address`;
    return execSync(cmd, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return null;
  }
}
