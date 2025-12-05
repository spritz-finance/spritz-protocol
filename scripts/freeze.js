#!/usr/bin/env node

/**
 * Freeze Script - Creates immutable deployment packages for Solidity contracts
 *
 * Uses official Forge tools (forge inspect) to extract bytecode reliably.
 *
 * Usage:
 *   node scripts/freeze.js <ContractName>        Freeze a contract for deployment
 *   node scripts/freeze.js --delete <Contract>   Delete a frozen build
 *   node scripts/freeze.js --list                List all frozen contracts
 */

const { execSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const DEPLOYMENTS_DIR = path.join(__dirname, "..", "deployments");
const SRC_DIR = path.join(__dirname, "..", "src");

const colors = {
  reset: "\x1b[0m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  dim: "\x1b[2m",
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

function run(cmd, options = {}) {
  try {
    return execSync(cmd, {
      encoding: "utf8",
      stdio: options.silent ? "pipe" : "inherit",
      cwd: path.join(__dirname, ".."),
      ...options,
    });
  } catch (e) {
    if (options.silent) return null;
    throw e;
  }
}

function forgeInspect(contractName, field) {
  const result = run(`forge inspect ${contractName} ${field}`, {
    silent: true,
    encoding: "utf8",
  });
  if (!result) {
    throw new Error(`Failed to inspect ${contractName} ${field}`);
  }
  return result.trim();
}

function findContractSource(contractName) {
  const directPath = path.join(SRC_DIR, `${contractName}.sol`);
  if (fs.existsSync(directPath)) {
    return directPath;
  }

  const files = fs.readdirSync(SRC_DIR, { recursive: true });
  for (const file of files) {
    if (file.endsWith(`${contractName}.sol`)) {
      return path.join(SRC_DIR, file);
    }
  }

  return null;
}

function extractImports(sourceCode) {
  const imports = [];
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

function copySourceWithDeps(contractName, sourcePath, destDir) {
  const srcSubdir = path.join(destDir, "src");
  fs.mkdirSync(srcSubdir, { recursive: true });

  const sourceCode = fs.readFileSync(sourcePath, "utf8");
  fs.writeFileSync(path.join(srcSubdir, `${contractName}.sol`), sourceCode);

  const imports = extractImports(sourceCode);

  for (const imp of imports) {
    let resolvedPath;
    if (imp.startsWith("./")) {
      resolvedPath = path.join(path.dirname(sourcePath), imp);
    } else {
      resolvedPath = path.join(SRC_DIR, imp);
    }

    if (fs.existsSync(resolvedPath)) {
      const relDir = path.dirname(imp.replace(/^\.\//, ""));
      const destSubdir = path.join(srcSubdir, relDir);
      fs.mkdirSync(destSubdir, { recursive: true });

      const fileName = path.basename(resolvedPath);
      fs.copyFileSync(resolvedPath, path.join(destSubdir, fileName));
    }
  }

  const interfacesDir = path.join(SRC_DIR, "interfaces");
  if (fs.existsSync(interfacesDir)) {
    const destInterfacesDir = path.join(srcSubdir, "interfaces");
    fs.mkdirSync(destInterfacesDir, { recursive: true });

    const interfaces = fs.readdirSync(interfacesDir);
    for (const iface of interfaces) {
      if (iface.endsWith(".sol")) {
        fs.copyFileSync(
          path.join(interfacesDir, iface),
          path.join(destInterfacesDir, iface)
        );
      }
    }
  }
}

function generateChecksums(dir) {
  const checksums = [];

  function walkDir(currentDir, relativePath = "") {
    const files = fs.readdirSync(currentDir);
    for (const file of files) {
      const fullPath = path.join(currentDir, file);
      const relPath = path.join(relativePath, file);
      const stat = fs.statSync(fullPath);

      if (stat.isDirectory()) {
        walkDir(fullPath, relPath);
      } else {
        const content = fs.readFileSync(fullPath);
        const hash = crypto.createHash("sha256").update(content).digest("hex");
        checksums.push(`${hash}  ./${relPath}`);
      }
    }
  }

  walkDir(dir);
  return checksums.sort().join("\n");
}

function freezeContract(contractName) {
  log("");
  info(`Freezing ${contractName}...`);
  log("");

  const deploymentDir = path.join(DEPLOYMENTS_DIR, contractName);
  if (fs.existsSync(deploymentDir)) {
    error(`${contractName} is already frozen.`);
    log("");
    log(`  To re-freeze, first delete the existing build:`);
    log(
      `  ${colors.dim}node scripts/freeze.js --delete ${contractName}${colors.reset}`
    );
    log("");
    process.exit(1);
  }

  const sourcePath = findContractSource(contractName);
  if (!sourcePath) {
    error(`Could not find source file for ${contractName}`);
    log(`  Looked for: src/${contractName}.sol`);
    process.exit(1);
  }
  success(`Found source: ${path.relative(process.cwd(), sourcePath)}`);

  info("Building contracts (forge build --force)...");
  run("forge build --force");
  success("Build complete");

  fs.mkdirSync(deploymentDir, { recursive: true });
  const artifactsDir = path.join(deploymentDir, "artifacts");
  const verifyDir = path.join(deploymentDir, "verify");
  fs.mkdirSync(artifactsDir);
  fs.mkdirSync(verifyDir);

  info("Extracting bytecode via forge inspect...");

  // Use forge inspect for reliable bytecode extraction
  const initcode = forgeInspect(contractName, "bytecode");
  const deployedBytecode = forgeInspect(contractName, "deployedBytecode");

  // Validate we got valid bytecode
  if (!initcode.startsWith("0x") || initcode.length < 10) {
    error("Invalid initcode returned from forge inspect");
    process.exit(1);
  }
  if (!deployedBytecode.startsWith("0x") || deployedBytecode.length < 10) {
    error("Invalid deployedBytecode returned from forge inspect");
    process.exit(1);
  }

  fs.writeFileSync(path.join(artifactsDir, `${contractName}.initcode`), initcode);
  fs.writeFileSync(
    path.join(artifactsDir, `${contractName}.deployed`),
    deployedBytecode
  );

  // Also save full artifact JSON
  const artifactJson = forgeInspect(contractName, "metadata");
  fs.writeFileSync(
    path.join(artifactsDir, `${contractName}.metadata.json`),
    artifactJson
  );

  success("Bytecode extracted via forge inspect");

  info("Generating verification JSON...");
  const verifyOutput = run(
    `forge verify-contract --show-standard-json-input 0x0000000000000000000000000000000000000000 ${contractName}`,
    { silent: true, encoding: "utf8" }
  );
  if (verifyOutput) {
    fs.writeFileSync(
      path.join(verifyDir, "standard-json-input.json"),
      verifyOutput
    );
    success("Verification JSON generated");
  } else {
    warn("Could not generate verification JSON (non-fatal)");
  }

  info("Copying source files...");
  copySourceWithDeps(contractName, sourcePath, deploymentDir);
  success("Source files copied");

  info("Copying foundry.toml...");
  fs.copyFileSync(
    path.join(__dirname, "..", "foundry.toml"),
    path.join(deploymentDir, "foundry.toml")
  );
  success("Config copied");

  info("Generating metadata...");
  let gitCommit = "unknown";
  let gitBranch = "unknown";
  try {
    gitCommit = run("git rev-parse HEAD", {
      silent: true,
      encoding: "utf8",
    }).trim();
    gitBranch = run("git rev-parse --abbrev-ref HEAD", {
      silent: true,
      encoding: "utf8",
    }).trim();
  } catch {}

  // Use cast keccak for hash (same as Solidity)
  const initcodeHash = run(`cast keccak ${initcode}`, {
    silent: true,
    encoding: "utf8",
  }).trim();

  const metadata = {
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

  fs.writeFileSync(
    path.join(deploymentDir, "metadata.json"),
    JSON.stringify(metadata, null, 2)
  );
  success("Metadata generated");

  info("Generating checksums...");
  const checksums = generateChecksums(deploymentDir);
  fs.writeFileSync(path.join(deploymentDir, "checksums.sha256"), checksums);
  success("Checksums generated");

  log("");
  log(
    `${colors.green}═══════════════════════════════════════════════════════════${colors.reset}`
  );
  log(`${colors.green}  ${contractName} frozen successfully${colors.reset}`);
  log(
    `${colors.green}═══════════════════════════════════════════════════════════${colors.reset}`
  );
  log("");
  log(`  Location: ${colors.dim}deployments/${contractName}/${colors.reset}`);
  log(
    `  Initcode hash: ${colors.dim}${initcodeHash.slice(0, 18)}...${colors.reset}`
  );
  log("");
  log(`  Next steps:`);
  log(`  1. Generate a vanity salt with createXcrunch`);
  log(`  2. Update Deploy.s.sol with the salt and initcode hash`);
  log(`  3. Commit: ${colors.dim}git add deployments/${contractName}${colors.reset}`);
  log("");
}

function deleteContract(contractName, force = false) {
  const deploymentDir = path.join(DEPLOYMENTS_DIR, contractName);

  if (!fs.existsSync(deploymentDir)) {
    error(`${contractName} is not frozen.`);
    log("");
    log(`  Available frozen contracts:`);
    listContracts();
    process.exit(1);
  }

  // Check for active deployments
  const metadataPath = path.join(deploymentDir, "metadata.json");
  if (fs.existsSync(metadataPath)) {
    const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
    if (metadata.deployments && metadata.deployments.length > 0) {
      error(
        `${contractName} has ${metadata.deployments.length} active deployment(s).`
      );
      log("");
      log(`  Deployments:`);
      for (const dep of metadata.deployments) {
        log(
          `    ${colors.dim}${dep.id || "unknown"}${colors.reset}: ${dep.address} (${dep.chains.join(", ")})`
        );
      }
      log("");
      if (!force) {
        log(
          `  Use ${colors.dim}--force${colors.reset} to delete anyway (dangerous!)`
        );
        log("");
        process.exit(1);
      }
      warn("Proceeding with --force flag...");
    }
  }

  info(`Deleting frozen build for ${contractName}...`);
  fs.rmSync(deploymentDir, { recursive: true });
  success(`Deleted deployments/${contractName}`);
  log("");
}

function listContracts() {
  if (!fs.existsSync(DEPLOYMENTS_DIR)) {
    log("");
    info("No frozen contracts yet.");
    log("");
    return;
  }

  const entries = fs.readdirSync(DEPLOYMENTS_DIR, { withFileTypes: true });
  const contracts = entries.filter(
    (e) =>
      e.isDirectory() &&
      fs.existsSync(path.join(DEPLOYMENTS_DIR, e.name, "metadata.json"))
  );

  if (contracts.length === 0) {
    log("");
    info("No frozen contracts yet.");
    log("");
    return;
  }

  log("");
  log(`${colors.blue}Frozen Contracts${colors.reset}`);
  log(`${"─".repeat(60)}`);

  for (const contract of contracts) {
    const metadataPath = path.join(
      DEPLOYMENTS_DIR,
      contract.name,
      "metadata.json"
    );
    const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));

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

function printUsage() {
  log("");
  log(
    `${colors.blue}Freeze Script${colors.reset} - Create immutable deployment packages`
  );
  log("");
  log(`Usage:`);
  log(
    `  node scripts/freeze.js <ContractName>                Freeze a contract`
  );
  log(
    `  node scripts/freeze.js --delete <Contract>           Delete a frozen build`
  );
  log(
    `  node scripts/freeze.js --delete <Contract> --force   Force delete (even with deployments)`
  );
  log(`  node scripts/freeze.js --list                        List frozen contracts`);
  log("");
  log(`Examples:`);
  log(`  ${colors.dim}node scripts/freeze.js SpritzPayCore${colors.reset}`);
  log(
    `  ${colors.dim}node scripts/freeze.js --delete SpritzPayCore${colors.reset}`
  );
  log("");
}

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
    log(`  Usage: node scripts/freeze.js --delete <ContractName>`);
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
