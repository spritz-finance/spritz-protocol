#!/usr/bin/env bun

/**
 * Freeze Script - Creates immutable deployment packages for Solidity contracts
 *
 * Uses official Forge tools (forge inspect) to extract bytecode reliably.
 *
 * Usage:
 *   bun freeze <ContractName>                Freeze a contract for deployment
 *   bun freeze --delete <Contract>           Delete a frozen build
 *   bun freeze --list                        List all frozen contracts
 */

import { execSync } from "child_process";
import { createHash, randomUUID } from "crypto";
import { existsSync, readFileSync, writeFileSync, readdirSync, mkdirSync, rmSync, statSync, copyFileSync } from "fs";
import { join, dirname, basename, relative } from "path";
import { log, success, error, info, warn, colors } from "./lib/console";

const DEPLOYMENTS_DIR = join(process.cwd(), "deployments");
const SRC_DIR = join(process.cwd(), "src");

function run(cmd: string, options: { silent?: boolean; encoding?: BufferEncoding; cwd?: string } = {}): string | null {
  try {
    return execSync(cmd, {
      encoding: options.encoding ?? "utf8",
      stdio: options.silent ? "pipe" : "inherit",
      cwd: options.cwd ?? process.cwd(),
    }) as string;
  } catch {
    if (options.silent) return null;
    throw new Error(`Command failed: ${cmd}`);
  }
}

function forgeInspect(contractName: string, field: string): string {
  const result = run(`forge inspect ${contractName} ${field}`, {
    silent: true,
    encoding: "utf8",
  });
  if (!result) {
    throw new Error(`Failed to inspect ${contractName} ${field}`);
  }
  return result.trim();
}

function findContractSource(contractName: string): string | null {
  const directPath = join(SRC_DIR, `${contractName}.sol`);
  if (existsSync(directPath)) {
    return directPath;
  }

  const files = readdirSync(SRC_DIR, { recursive: true }) as string[];
  for (const file of files) {
    if (file.endsWith(`${contractName}.sol`)) {
      return join(SRC_DIR, file);
    }
  }

  return null;
}

function extractImports(sourceCode: string): string[] {
  const imports: string[] = [];
  const importRegex = /import\s+(?:{[^}]+}\s+from\s+)?["']([^"']+)["']/g;
  let match;

  while ((match = importRegex.exec(sourceCode)) !== null) {
    const importPath = match[1];
    if (importPath.startsWith("./") || importPath.startsWith("../")) {
      imports.push(importPath);
    } else if (
      importPath.startsWith("./interfaces/") ||
      importPath.includes("/interfaces/")
    ) {
      imports.push(importPath);
    }
  }

  return imports;
}

function copySourceWithDeps(contractName: string, sourcePath: string, destDir: string): void {
  const srcSubdir = join(destDir, "src");
  mkdirSync(srcSubdir, { recursive: true });

  const sourceCode = readFileSync(sourcePath, "utf8");
  writeFileSync(join(srcSubdir, `${contractName}.sol`), sourceCode);

  const imports = extractImports(sourceCode);

  for (const imp of imports) {
    let resolvedPath: string;
    if (imp.startsWith("./")) {
      resolvedPath = join(dirname(sourcePath), imp);
    } else {
      resolvedPath = join(SRC_DIR, imp);
    }

    if (existsSync(resolvedPath)) {
      const relDir = dirname(imp.replace(/^\.\//, ""));
      const destSubdir = join(srcSubdir, relDir);
      mkdirSync(destSubdir, { recursive: true });

      const fileName = basename(resolvedPath);
      copyFileSync(resolvedPath, join(destSubdir, fileName));
    }
  }

  const interfacesDir = join(SRC_DIR, "interfaces");
  if (existsSync(interfacesDir)) {
    const destInterfacesDir = join(srcSubdir, "interfaces");
    mkdirSync(destInterfacesDir, { recursive: true });

    const interfaces = readdirSync(interfacesDir);
    for (const iface of interfaces) {
      if (iface.endsWith(".sol")) {
        copyFileSync(
          join(interfacesDir, iface),
          join(destInterfacesDir, iface)
        );
      }
    }
  }
}

function generateChecksums(dir: string): string {
  const checksums: string[] = [];

  function walkDir(currentDir: string, relativePath: string = ""): void {
    const files = readdirSync(currentDir);
    for (const file of files) {
      const fullPath = join(currentDir, file);
      const relPath = join(relativePath, file);
      const stat = statSync(fullPath);

      if (stat.isDirectory()) {
        walkDir(fullPath, relPath);
      } else {
        const content = readFileSync(fullPath);
        const hash = createHash("sha256").update(content).digest("hex");
        checksums.push(`${hash}  ./${relPath}`);
      }
    }
  }

  walkDir(dir);
  return checksums.sort().join("\n");
}

interface DeploymentRecord {
  id: string;
  deployer: string;
  address: string;
  salt: string;
  environment?: string;
  chains: string[];
  constructorArgs?: string[];
}

interface Metadata {
  contract: string;
  frozenAt: string;
  gitCommit: string;
  gitBranch: string;
  compiler: {
    solc: string;
    evmVersion: string;
    optimizer: boolean;
    optimizerRuns: number;
    viaIR: boolean;
    cborMetadata: boolean;
    bytecodeHash: string;
  };
  initcodeHash: string;
  deployments: DeploymentRecord[];
}

function getMetadata(contractName: string): Metadata | null {
  const metadataPath = join(DEPLOYMENTS_DIR, contractName, "metadata.json");
  if (!existsSync(metadataPath)) {
    return null;
  }
  return JSON.parse(readFileSync(metadataPath, "utf8"));
}

function freezeContract(contractName: string): void {
  log("");
  info(`Freezing ${contractName}...`);
  log("");

  const deploymentDir = join(DEPLOYMENTS_DIR, contractName);
  if (existsSync(deploymentDir)) {
    error(`${contractName} is already frozen.`);
    log("");
    log(`  To re-freeze, first delete the existing build:`);
    log(`  ${colors.dim}bun freeze --delete ${contractName}${colors.reset}`);
    log("");
    process.exit(1);
  }

  const sourcePath = findContractSource(contractName);
  if (!sourcePath) {
    error(`Could not find source file for ${contractName}`);
    log(`  Looked for: src/${contractName}.sol`);
    process.exit(1);
  }
  success(`Found source: ${relative(process.cwd(), sourcePath)}`);

  info("Building contracts (forge build --force)...");
  run("forge build --force");
  success("Build complete");

  mkdirSync(deploymentDir, { recursive: true });
  const artifactsDir = join(deploymentDir, "artifacts");
  const verifyDir = join(deploymentDir, "verify");
  mkdirSync(artifactsDir);
  mkdirSync(verifyDir);

  info("Extracting bytecode via forge inspect...");

  const initcode = forgeInspect(contractName, "bytecode");
  const deployedBytecode = forgeInspect(contractName, "deployedBytecode");

  if (!initcode.startsWith("0x") || initcode.length < 10) {
    error("Invalid initcode returned from forge inspect");
    process.exit(1);
  }
  if (!deployedBytecode.startsWith("0x") || deployedBytecode.length < 10) {
    error("Invalid deployedBytecode returned from forge inspect");
    process.exit(1);
  }

  writeFileSync(join(artifactsDir, `${contractName}.initcode`), initcode);
  writeFileSync(join(artifactsDir, `${contractName}.deployed`), deployedBytecode);

  const artifactJson = forgeInspect(contractName, "metadata");
  writeFileSync(join(artifactsDir, `${contractName}.metadata.json`), artifactJson);

  const abi = forgeInspect(contractName, "abi");
  writeFileSync(join(artifactsDir, `${contractName}.abi.json`), abi);

  success("Bytecode and ABI extracted via forge inspect");

  info("Generating verification JSON...");
  const verifyOutput = run(
    `forge verify-contract --show-standard-json-input --root . 0x0000000000000000000000000000000000000000 ${contractName}`,
    { silent: true, encoding: "utf8" }
  );
  if (verifyOutput && verifyOutput.trim().startsWith("{")) {
    writeFileSync(join(verifyDir, "standard-json-input.json"), verifyOutput);
    success("Verification JSON generated");
  } else {
    warn("Could not generate verification JSON (non-fatal)");
    log(`  ${colors.dim}You can generate it manually with:${colors.reset}`);
    log(`  ${colors.dim}forge verify-contract --show-standard-json-input <address> ${contractName}${colors.reset}`);
  }

  info("Copying source files...");
  copySourceWithDeps(contractName, sourcePath, deploymentDir);
  success("Source files copied");

  info("Copying foundry.toml...");
  copyFileSync(join(process.cwd(), "foundry.toml"), join(deploymentDir, "foundry.toml"));
  success("Config copied");

  info("Generating metadata...");
  let gitCommit = "unknown";
  let gitBranch = "unknown";
  try {
    gitCommit = run("git rev-parse HEAD", { silent: true, encoding: "utf8" })?.trim() ?? "unknown";
    gitBranch = run("git rev-parse --abbrev-ref HEAD", { silent: true, encoding: "utf8" })?.trim() ?? "unknown";
  } catch { /* ignore */ }

  const initcodeHash = run(`cast keccak ${initcode}`, { silent: true, encoding: "utf8" })?.trim() ?? "";

  const metadata: Metadata = {
    contract: contractName,
    frozenAt: new Date().toISOString(),
    gitCommit,
    gitBranch,
    compiler: {
      solc: "0.8.30",
      evmVersion: "cancun",
      optimizer: true,
      optimizerRuns: 10000000,
      viaIR: false,
      cborMetadata: false,
      bytecodeHash: "none",
    },
    initcodeHash,
    deployments: [],
  };

  writeFileSync(join(deploymentDir, "metadata.json"), JSON.stringify(metadata, null, 2));
  success("Metadata generated");

  info("Generating checksums...");
  const checksums = generateChecksums(deploymentDir);
  writeFileSync(join(deploymentDir, "checksums.sha256"), checksums);
  success("Checksums generated");

  log("");
  log(`${colors.green}═══════════════════════════════════════════════════════════${colors.reset}`);
  log(`${colors.green}  ${contractName} frozen successfully${colors.reset}`);
  log(`${colors.green}═══════════════════════════════════════════════════════════${colors.reset}`);
  log("");
  log(`  Location: ${colors.dim}deployments/${contractName}/${colors.reset}`);
  log(`  Initcode hash: ${colors.dim}${initcodeHash.slice(0, 18)}...${colors.reset}`);
  log("");
  log(`  Next steps:`);
  log(`  1. Generate a vanity salt with createXcrunch`);
  log(`  2. Update Deploy.s.sol with the salt and initcode hash`);
  log(`  3. Commit: ${colors.dim}git add deployments/${contractName}${colors.reset}`);
  log("");
}

function deleteContract(contractName: string, force: boolean = false): void {
  const deploymentDir = join(DEPLOYMENTS_DIR, contractName);

  if (!existsSync(deploymentDir)) {
    error(`${contractName} is not frozen.`);
    log("");
    log(`  Available frozen contracts:`);
    listContracts();
    process.exit(1);
  }

  const metadata = getMetadata(contractName);
  if (metadata?.deployments && metadata.deployments.length > 0) {
    error(`${contractName} has ${metadata.deployments.length} active deployment(s).`);
    log("");
    log(`  Deployments:`);
    for (const dep of metadata.deployments) {
      log(`    ${colors.dim}${dep.id || "unknown"}${colors.reset}: ${dep.address} (${dep.chains.join(", ")})`);
    }
    log("");
    if (!force) {
      log(`  Use ${colors.dim}--force${colors.reset} to delete anyway (dangerous!)`);
      log("");
      process.exit(1);
    }
    warn("Proceeding with --force flag...");
  }

  info(`Deleting frozen build for ${contractName}...`);
  rmSync(deploymentDir, { recursive: true });
  success(`Deleted deployments/${contractName}`);
  log("");
}

function listContracts(): void {
  if (!existsSync(DEPLOYMENTS_DIR)) {
    log("");
    info("No frozen contracts yet.");
    log("");
    return;
  }

  const entries = readdirSync(DEPLOYMENTS_DIR, { withFileTypes: true });
  const contracts = entries.filter(
    (e) =>
      e.isDirectory() &&
      existsSync(join(DEPLOYMENTS_DIR, e.name, "metadata.json"))
  );

  if (contracts.length === 0) {
    log("");
    info("No frozen contracts yet.");
    log("");
    return;
  }

  log("");
  log(`${colors.blue}Frozen Contracts${colors.reset}`);
  log("─".repeat(60));

  for (const contract of contracts) {
    const metadata = getMetadata(contract.name);
    if (!metadata) continue;

    const frozenAt = metadata.frozenAt
      ? new Date(metadata.frozenAt).toLocaleDateString()
      : "unknown";
    const deployments = metadata.deployments || [];

    log("");
    log(`  ${colors.green}${contract.name}${colors.reset}`);
    log(`  ${colors.dim}Frozen: ${frozenAt}${colors.reset}`);
    log(`  ${colors.dim}Hash: ${metadata.initcodeHash?.slice(0, 18)}...${colors.reset}`);

    if (deployments.length === 0) {
      log(`  ${colors.dim}Not deployed yet${colors.reset}`);
    } else {
      for (const dep of deployments) {
        log(`  ${colors.dim}${dep.address} (${dep.chains.join(", ")})${colors.reset}`);
      }
    }
  }

  log("");
}

function printUsage(): void {
  log("");
  log(`${colors.blue}Freeze Script${colors.reset} - Create immutable deployment packages`);
  log("");
  log(`Usage:`);
  log(`  bun freeze <ContractName>                Freeze a contract`);
  log(`  bun freeze --delete <Contract>           Delete a frozen build`);
  log(`  bun freeze --delete <Contract> --force   Force delete (even with deployments)`);
  log(`  bun freeze --list                        List frozen contracts`);
  log("");
  log(`Examples:`);
  log(`  ${colors.dim}bun freeze SpritzPayCore${colors.reset}`);
  log(`  ${colors.dim}bun freeze --delete SpritzPayCore${colors.reset}`);
  log("");
}

function main(): void {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") {
    printUsage();
    process.exit(0);
  }

  if (args[0] === "--list" || args[0] === "-l") {
    listContracts();
    process.exit(0);
  }

  if (args[0] === "--delete" || args[0] === "-d") {
    if (!args[1]) {
      error("Missing contract name");
      log(`  Usage: bun freeze --delete <ContractName>`);
      process.exit(1);
    }
    const force = args.includes("--force") || args.includes("-f");
    deleteContract(args[1], force);
    process.exit(0);
  }

  if (args[0].startsWith("-")) {
    error(`Unknown option: ${args[0]}`);
    printUsage();
    process.exit(1);
  }

  freezeContract(args[0]);
}

main();
