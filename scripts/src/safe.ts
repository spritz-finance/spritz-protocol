#!/usr/bin/env bun

/**
 * Safe Admin CLI - Manage Spritz contracts via Safe multisig
 *
 * Commands:
 *   bun safe status <chain>                  Show current contract configuration
 *   bun safe list <chain>                    List pending transactions
 *   bun safe sign <chain> <safeTxHash>       Sign a pending transaction
 *   bun safe execute <chain> <safeTxHash>    Execute a fully-signed transaction
 *
 * Actions:
 *   bun safe setSwapModule <chain> <moduleAddress>         Set the swap module on Router
 *   bun safe addPaymentToken <chain> <token> <recipient>   Add a payment token on Core
 *   bun safe removePaymentToken <chain> <token>            Remove a payment token from Core
 *   bun safe sweep <chain> <contract> <token> <to>         Sweep tokens from a contract
 */

import { execSync } from "child_process";
import { ethers } from "ethers";
import { existsSync, readFileSync } from "fs";
import { join } from "path";
import prompts from "prompts";
import { loadContractSaltOverrides, loadEnv, loadSigners, type SignerEnv } from "./lib/env";
import { applyEnvOverrides, loadConfig, type Config } from "./lib/config";
import { buildChains, type Chain } from "./lib/chains";
import { getContractAddress } from "./lib/createx";
import { log, success, error, info, warn, colors } from "./lib/console";

const DEPLOYMENTS_DIR = join(process.cwd(), "deployments");

const env = loadEnv();
const saltOverrides = loadContractSaltOverrides();
const baseConfig = loadConfig();
const { config } = applyEnvOverrides(baseConfig, {
  DEPLOYER_ADDRESS: env.DEPLOYER_ADDRESS,
  DEPLOYER_KEY_REF: env.DEPLOYER_KEY_REF,
  contractSalts: saltOverrides,
});
const SIGNERS = loadSigners();
const SAFE_API_KEY = env.SAFE_API_KEY;

if (SIGNERS.length === 0) {
  error("No signers configured. Create .env file with SIGNER_1_NAME, SIGNER_1_KEY_REF, etc.");
  log("See .env.example for format.");
  process.exit(1);
}

if (!SAFE_API_KEY) {
  warn("SAFE_API_KEY not set. Safe API operations may fail.");
  log("Get an API key from https://safe.global/ and add SAFE_API_KEY to .env");
  log("");
}

const CHAINS = buildChains(config, env.RPC_KEY ?? "");

const ROUTER_ABI = [
  "function setSwapModule(address newSwapModule) external",
  "function sweep(address token, address to) external",
  "function owner() view returns (address)",
  "function swapModule() view returns (address)",
];

const CORE_ABI = [
  "function addPaymentToken(address token, address recipient) external",
  "function removePaymentToken(address token) external",
  "function sweep(address token, address to) external",
  "function owner() view returns (address)",
  "function isAcceptedToken(address token) view returns (bool)",
  "function paymentRecipient(address token) view returns (address)",
  "function acceptedPaymentTokens() view returns (address[])",
];

const ERC20_ABI = [
  "function symbol() view returns (string)",
];

function getPrivateKey(keyRef: string): string | null {
  try {
    return execSync(`op read "${keyRef}"`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return null;
  }
}

function getSignerByName(name: string): SignerEnv | undefined {
  return SIGNERS.find((s) => s.name === name);
}

function getSignerByAddress(address: string): SignerEnv | undefined {
  return SIGNERS.find((s) => s.address?.toLowerCase() === address.toLowerCase());
}

async function selectSigner(
  prompt: string,
  excludeAddresses: string[] = []
): Promise<SignerEnv | null> {
  const excludeLower = excludeAddresses.map((a) => a.toLowerCase());
  const availableSigners = SIGNERS.filter(
    (s) => !s.address || !excludeLower.includes(s.address.toLowerCase())
  );

  if (availableSigners.length === 0) {
    return null;
  }

  if (availableSigners.length === 1) {
    return availableSigners[0];
  }

  const response = await prompts({
    type: "select",
    name: "signer",
    message: prompt,
    choices: availableSigners.map((s) => ({
      title: `${s.name}${s.address ? ` (${s.address.slice(0, 8)}...)` : ""}`,
      value: s,
    })),
  });

  return response.signer || null;
}

async function confirmAction(message: string): Promise<boolean> {
  const response = await prompts({
    type: "confirm",
    name: "confirmed",
    message,
    initial: true,
  });

  return response.confirmed ?? false;
}

interface DeploymentRecord {
  id: string;
  deployer: string;
  address: string;
  salt: string;
  chains: string[];
}

interface Metadata {
  contract: string;
  deployments: DeploymentRecord[];
}

interface ContractAddresses {
  core: { address: string; recorded: boolean };
  router: { address: string; recorded: boolean };
}

function getDeploymentAddresses(chainName: string): ContractAddresses | null {
  const coreMetadataPath = join(DEPLOYMENTS_DIR, "SpritzPayCore", "metadata.json");
  const routerMetadataPath = join(DEPLOYMENTS_DIR, "SpritzRouter", "metadata.json");

  let coreAddress: string | null = null;
  let coreRecorded = false;
  let routerAddress: string | null = null;
  let routerRecorded = false;

  if (existsSync(coreMetadataPath)) {
    const coreMetadata: Metadata = JSON.parse(readFileSync(coreMetadataPath, "utf8"));
    const coreDep = coreMetadata.deployments?.find((d) => d.chains.includes(chainName));
    if (coreDep) {
      coreAddress = coreDep.address;
      coreRecorded = true;
    }
  }

  if (existsSync(routerMetadataPath)) {
    const routerMetadata: Metadata = JSON.parse(readFileSync(routerMetadataPath, "utf8"));
    const routerDep = routerMetadata.deployments?.find((d) => d.chains.includes(chainName));
    if (routerDep) {
      routerAddress = routerDep.address;
      routerRecorded = true;
    }
  }

  if (!coreAddress) {
    coreAddress = getContractAddress(config, "SpritzPayCore");
  }

  if (!routerAddress) {
    routerAddress = getContractAddress(config, "SpritzRouter");
  }

  if (!coreAddress || !routerAddress) {
    return null;
  }

  return {
    core: { address: coreAddress, recorded: coreRecorded },
    router: { address: routerAddress, recorded: routerRecorded },
  };
}

let Safe: typeof import("@safe-global/protocol-kit").default;
let SafeApiKit: typeof import("@safe-global/api-kit").default;

async function loadSafeSDK(): Promise<void> {
  if (!Safe) {
    try {
      const protocolKit = await import("@safe-global/protocol-kit");
      const apiKit = await import("@safe-global/api-kit");
      Safe = protocolKit.default;
      SafeApiKit = apiKit.default;
    } catch {
      error("Safe SDK not installed. Run:");
      log("");
      log("  bun add @safe-global/protocol-kit @safe-global/api-kit ethers");
      log("");
      process.exit(1);
    }
  }
}

interface SafeContext {
  protocolKit: Awaited<ReturnType<typeof Safe.init>>;
  apiKit: InstanceType<typeof SafeApiKit>;
  signer: ethers.Wallet;
  chain: Chain;
  safeAddress: string;
  signerConfig: SignerEnv;
}

interface InitSafeOptions {
  chainName: string;
  signerConfig?: SignerEnv;
  signerName?: string;
}

async function initSafe(options: InitSafeOptions): Promise<SafeContext> {
  await loadSafeSDK();

  const { chainName, signerName } = options;
  let { signerConfig } = options;

  const chain = CHAINS[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    process.exit(1);
  }

  if (!chain.safeService) {
    error(`No Safe service configured for ${chainName}`);
    process.exit(1);
  }

  if (!signerConfig) {
    if (signerName) {
      const found = getSignerByName(signerName);
      if (!found) {
        error(`Unknown signer: ${signerName}`);
        log("");
        log("Available signers:");
        for (const s of SIGNERS) {
          log(`  - ${s.name}`);
        }
        process.exit(1);
      }
      signerConfig = found;
    } else {
      signerConfig = SIGNERS[0];
    }
  }

  info(`Using signer: ${signerConfig.name}`);

  const privateKey = getPrivateKey(signerConfig.keyRef);
  if (!privateKey) {
    error(`Failed to get key from 1Password: ${signerConfig.keyRef}`);
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(chain.rpc);

  const protocolKit = await Safe.init({
    provider: chain.rpc,
    signer: privateKey,
    safeAddress: chain.admin,
  });

  const apiKit = new SafeApiKit({
    chainId: BigInt(chain.chainId),
    ...(SAFE_API_KEY && { apiKey: SAFE_API_KEY }),
  });

  const signer = new ethers.Wallet(privateKey, provider);

  return { protocolKit, apiKit, signer, chain, safeAddress: chain.admin, signerConfig };
}

async function initApiKit(chainName: string): Promise<{ apiKit: InstanceType<typeof SafeApiKit>; chain: Chain; safeAddress: string }> {
  await loadSafeSDK();

  const chain = CHAINS[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    process.exit(1);
  }

  const apiKit = new SafeApiKit({
    chainId: BigInt(chain.chainId),
    ...(SAFE_API_KEY && { apiKey: SAFE_API_KEY }),
  });

  return { apiKit, chain, safeAddress: chain.admin };
}

async function listPendingTransactions(chainName: string): Promise<void> {
  const { apiKit, safeAddress } = await initApiKit(chainName);

  log("");
  log(`${colors.blue}Pending Transactions for ${chainName}${colors.reset}`);
  log("─".repeat(70));

  try {
    const pending = await apiKit.getPendingTransactions(safeAddress);

    if (!pending.results || pending.results.length === 0) {
      log("");
      info("No pending transactions");
      log("");
      return;
    }

    for (const tx of pending.results) {
      log("");
      log(`  ${colors.bold}Hash:${colors.reset} ${tx.safeTxHash}`);
      log(`  ${colors.dim}To:${colors.reset} ${tx.to}`);
      log(`  ${colors.dim}Value:${colors.reset} ${tx.value}`);
      log(`  ${colors.dim}Data:${colors.reset} ${tx.data?.slice(0, 50)}...`);
      log(`  ${colors.dim}Confirmations:${colors.reset} ${tx.confirmations?.length || 0}/${tx.confirmationsRequired}`);
      log(`  ${colors.dim}Nonce:${colors.reset} ${tx.nonce}`);
    }

    log("");
  } catch (e) {
    error(`Failed to fetch pending transactions: ${(e as Error).message}`);
  }
}

interface TransactionData {
  to: string;
  data: string;
  value: string;
}

async function proposeTransaction(
  chainName: string,
  transactions: TransactionData[],
  description: string
): Promise<string> {
  const { protocolKit, apiKit, signer, safeAddress } = await initSafe({ chainName });

  log("");
  info(`Proposing transaction to Safe on ${chainName}...`);
  log(`  Safe: ${safeAddress}`);
  log(`  Signer: ${signer.address}`);
  log(`  Target: ${transactions[0]?.to}`);
  log(`  Data: ${transactions[0]?.data?.slice(0, 20)}...`);
  log("");

  const safeTransaction = await protocolKit.createTransaction({ transactions });
  const safeTxHash = await protocolKit.getTransactionHash(safeTransaction);
  const signature = await protocolKit.signHash(safeTxHash);

  try {
    await apiKit.proposeTransaction({
      safeAddress,
      safeTransactionData: safeTransaction.data,
      safeTxHash,
      senderAddress: signer.address,
      senderSignature: signature.data,
      origin: "Spritz Safe CLI",
    });
  } catch (e) {
    const err = e as Error & { response?: { status?: number; data?: unknown } };
    if (err.response) {
      error(`API Error: ${err.response.status}`);
      log(`  ${JSON.stringify(err.response.data, null, 2)}`);
    }
    throw e;
  }

  success("Transaction proposed!");
  log("");
  log(`  ${colors.bold}Safe TX Hash:${colors.reset} ${safeTxHash}`);
  log(`  ${colors.bold}Description:${colors.reset} ${description}`);
  log("");
  log(`  Other signers can now sign via Safe UI or:`);
  log(`  ${colors.dim}bun safe sign ${chainName} ${safeTxHash}${colors.reset}`);
  log("");

  return safeTxHash;
}

async function signTransaction(chainName: string, safeTxHash: string): Promise<void> {
  const { apiKit, safeAddress } = await initApiKit(chainName);

  log("");
  info(`Loading transaction ${safeTxHash.slice(0, 18)}...`);

  const tx = await apiKit.getTransaction(safeTxHash);
  const confirmations = tx.confirmations || [];
  const threshold = tx.confirmationsRequired;
  const alreadySigned = confirmations.map((c) => c.owner);

  log("");
  log(`${colors.blue}Transaction Details${colors.reset}`);
  log("─".repeat(70));
  log(`  ${colors.bold}To:${colors.reset} ${tx.to}`);
  log(`  ${colors.bold}Value:${colors.reset} ${tx.value}`);
  log(`  ${colors.bold}Confirmations:${colors.reset} ${confirmations.length}/${threshold}`);
  log("");

  if (confirmations.length > 0) {
    log(`  ${colors.bold}Already signed by:${colors.reset}`);
    for (const conf of confirmations) {
      const knownSigner = getSignerByAddress(conf.owner);
      const name = knownSigner ? ` (${knownSigner.name})` : "";
      log(`    ${colors.green}✓${colors.reset} ${conf.owner}${name}`);
    }
    log("");
  }

  if (confirmations.length >= threshold) {
    log(`  ${colors.green}Already has enough signatures!${colors.reset}`);
    log("");
    const shouldExecute = await confirmAction("Execute transaction now?");
    if (shouldExecute) {
      await executeTransactionInternal(chainName, safeTxHash, tx);
    }
    return;
  }

  const signerConfig = await selectSigner("Select signer:", alreadySigned);
  if (!signerConfig) {
    if (alreadySigned.length > 0) {
      error("All configured signers have already signed this transaction.");
    } else {
      error("No signers available.");
    }
    process.exit(1);
  }

  const { protocolKit } = await initSafe({ chainName, signerConfig });

  log("");
  info(`Signing with ${signerConfig.name}...`);

  const signature = await protocolKit.signHash(safeTxHash);
  await apiKit.confirmTransaction(safeTxHash, signature.data);

  success("Transaction signed!");
  log("");

  const updatedTx = await apiKit.getTransaction(safeTxHash);
  const newConfirmations = updatedTx.confirmations?.length || 0;

  log(`  ${colors.bold}Confirmations:${colors.reset} ${newConfirmations}/${threshold}`);

  if (newConfirmations >= threshold) {
    log("");
    log(`  ${colors.green}Ready to execute!${colors.reset}`);
    log("");

    const shouldExecute = await confirmAction("Execute transaction now?");
    if (shouldExecute) {
      await executeTransactionInternal(chainName, safeTxHash, updatedTx);
    }
  } else {
    log(`  ${colors.yellow}Waiting for more signatures${colors.reset}`);
    log("");
  }
}

async function executeTransactionInternal(
  chainName: string,
  safeTxHash: string,
  tx: Awaited<ReturnType<InstanceType<typeof SafeApiKit>["getTransaction"]>>
): Promise<void> {
  const signerConfig = await selectSigner("Select signer to execute:");
  if (!signerConfig) {
    error("No signers available.");
    process.exit(1);
  }

  const { protocolKit, chain } = await initSafe({ chainName, signerConfig });

  log("");
  info(`Executing transaction...`);

  const response = await protocolKit.executeTransaction(tx);
  const txResponse = response.transactionResponse as { wait?: () => Promise<{ hash: string }> } | undefined;
  const receipt = await txResponse?.wait?.();

  success("Transaction executed!");
  log("");
  const txHash = receipt?.hash || response.hash;
  log(`  ${colors.bold}TX Hash:${colors.reset} ${txHash}`);
  log(`  ${colors.dim}${chain.explorer}/tx/${txHash}${colors.reset}`);
  log("");
}

async function executeTransaction(chainName: string, safeTxHash: string): Promise<void> {
  const { apiKit } = await initApiKit(chainName);

  log("");
  info(`Loading transaction ${safeTxHash.slice(0, 18)}...`);

  const tx = await apiKit.getTransaction(safeTxHash);
  const confirmations = tx.confirmations?.length || 0;
  const threshold = tx.confirmationsRequired;

  if (confirmations < threshold) {
    error(`Not enough signatures: ${confirmations}/${threshold}`);
    log("");
    log(`  Sign with: ${colors.dim}bun safe sign ${chainName} ${safeTxHash}${colors.reset}`);
    log("");
    process.exit(1);
  }

  await executeTransactionInternal(chainName, safeTxHash, tx);
}

async function setSwapModule(chainName: string, moduleAddress: string): Promise<void> {
  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const iface = new ethers.Interface(ROUTER_ABI);
  const data = iface.encodeFunctionData("setSwapModule", [moduleAddress]);

  const transactions: TransactionData[] = [
    {
      to: addresses.router.address,
      data,
      value: "0",
    },
  ];

  await proposeTransaction(chainName, transactions, `Set swap module to ${moduleAddress}`);
}

async function addPaymentToken(chainName: string, token: string, recipient: string): Promise<void> {
  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const iface = new ethers.Interface(CORE_ABI);
  const data = iface.encodeFunctionData("addPaymentToken", [token, recipient]);

  const transactions: TransactionData[] = [
    {
      to: addresses.core.address,
      data,
      value: "0",
    },
  ];

  await proposeTransaction(chainName, transactions, `Add payment token ${token} with recipient ${recipient}`);
}

async function removePaymentToken(chainName: string, token: string): Promise<void> {
  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const iface = new ethers.Interface(CORE_ABI);
  const data = iface.encodeFunctionData("removePaymentToken", [token]);

  const transactions: TransactionData[] = [
    {
      to: addresses.core.address,
      data,
      value: "0",
    },
  ];

  await proposeTransaction(chainName, transactions, `Remove payment token ${token}`);
}

async function sweep(chainName: string, contract: string, token: string, to: string): Promise<void> {
  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const targetAddress = contract === "core" ? addresses.core.address : addresses.router.address;
  const abi = contract === "core" ? CORE_ABI : ROUTER_ABI;

  const iface = new ethers.Interface(abi);
  const data = iface.encodeFunctionData("sweep", [token, to]);

  const transactions: TransactionData[] = [
    {
      to: targetAddress,
      data,
      value: "0",
    },
  ];

  await proposeTransaction(chainName, transactions, `Sweep ${token} from ${contract} to ${to}`);
}

interface ChainStatus {
  chainName: string;
  testnet: boolean;
  coreAddress: string;
  coreDeployed: boolean;
  coreOwner: string | null;
  paymentTokens: Array<{ address: string; symbol: string; recipient: string }>;
  routerAddress: string;
  routerDeployed: boolean;
  routerOwner: string | null;
  swapModule: string | null;
  error?: string;
}

async function getChainStatus(chainName: string): Promise<ChainStatus | null> {
  const chain = CHAINS[chainName];
  if (!chain) return null;

  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) return null;

  const status: ChainStatus = {
    chainName,
    testnet: chain.testnet,
    coreAddress: addresses.core.address,
    coreDeployed: addresses.core.recorded,
    coreOwner: null,
    paymentTokens: [],
    routerAddress: addresses.router.address,
    routerDeployed: addresses.router.recorded,
    routerOwner: null,
    swapModule: null,
  };

  try {
    const provider = new ethers.JsonRpcProvider(chain.rpc);
    const core = new ethers.Contract(addresses.core.address, CORE_ABI, provider);
    const router = new ethers.Contract(addresses.router.address, ROUTER_ABI, provider);

    const [coreOwner, tokens, routerOwner, swapModule] = await Promise.all([
      core.owner().catch(() => null),
      core.acceptedPaymentTokens().catch(() => []),
      router.owner().catch(() => null),
      router.swapModule().catch(() => null),
    ]);

    status.coreOwner = coreOwner;
    status.routerOwner = routerOwner;
    status.swapModule = swapModule;

    for (const token of tokens) {
      const [recipient, symbol] = await Promise.all([
        core.paymentRecipient(token).catch(() => "???"),
        new ethers.Contract(token, ERC20_ABI, provider).symbol().catch(() => "???"),
      ]);
      status.paymentTokens.push({ address: token, symbol, recipient });
    }
  } catch (e) {
    status.error = (e as Error).message;
  }

  return status;
}

function getDeployedChains(): string[] {
  const chains = new Set<string>();

  const coreMetadataPath = join(DEPLOYMENTS_DIR, "SpritzPayCore", "metadata.json");
  const routerMetadataPath = join(DEPLOYMENTS_DIR, "SpritzRouter", "metadata.json");

  if (existsSync(coreMetadataPath)) {
    const metadata: Metadata = JSON.parse(readFileSync(coreMetadataPath, "utf8"));
    for (const dep of metadata.deployments || []) {
      for (const chain of dep.chains) {
        chains.add(chain);
      }
    }
  }

  if (existsSync(routerMetadataPath)) {
    const metadata: Metadata = JSON.parse(readFileSync(routerMetadataPath, "utf8"));
    for (const dep of metadata.deployments || []) {
      for (const chain of dep.chains) {
        chains.add(chain);
      }
    }
  }

  return Array.from(chains);
}

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

async function showAllStatus(): Promise<void> {
  const deployedChains = getDeployedChains();

  if (deployedChains.length === 0) {
    log("");
    warn("No deployments found.");
    log("Deploy contracts first with: bun deployment deploy <chain>");
    log("");
    return;
  }

  log("");
  log(`${colors.blue}Deployment Status Overview${colors.reset}`);
  log("═".repeat(90));

  const mainnets = deployedChains.filter((c) => CHAINS[c] && !CHAINS[c].testnet);
  const testnets = deployedChains.filter((c) => CHAINS[c] && CHAINS[c].testnet);

  const allChains = [...mainnets, ...testnets];

  for (const chainName of allChains) {
    const status = await getChainStatus(chainName);
    if (!status) continue;

    const chainLabel = status.testnet
      ? `${colors.yellow}${chainName}${colors.reset} ${colors.dim}(testnet)${colors.reset}`
      : `${colors.bold}${chainName}${colors.reset}`;

    log("");
    log(`${chainLabel}`);
    log("─".repeat(90));

    if (status.error) {
      log(`  ${colors.red}Error: ${status.error}${colors.reset}`);
      continue;
    }

    const coreStatus = status.coreDeployed
      ? `${colors.green}✓${colors.reset}`
      : `${colors.yellow}○${colors.reset}`;
    const routerStatus = status.routerDeployed
      ? `${colors.green}✓${colors.reset}`
      : `${colors.yellow}○${colors.reset}`;

    log(`  ${coreStatus} Core   ${colors.dim}${status.coreAddress}${colors.reset}`);

    if (status.paymentTokens.length === 0) {
      log(`           ${colors.red}⚠ No payment tokens configured${colors.reset}`);
    } else {
      const tokenList = status.paymentTokens.map((t) => t.symbol).join(", ");
      log(`           Tokens: ${tokenList}`);
    }

    log(`  ${routerStatus} Router ${colors.dim}${status.routerAddress}${colors.reset}`);

    if (!status.swapModule || status.swapModule === ZERO_ADDRESS) {
      log(`           ${colors.red}⚠ No swap module configured${colors.reset}`);
    } else {
      log(`           Swap Module: ${colors.dim}${status.swapModule}${colors.reset}`);
    }
  }

  log("");
  log("─".repeat(90));
  log(`${colors.dim}Legend: ${colors.green}✓${colors.reset}${colors.dim} deployed  ${colors.yellow}○${colors.reset}${colors.dim} computed (not yet deployed)${colors.reset}`);
  log("");
}

async function showStatus(chainName: string): Promise<void> {
  const chain = CHAINS[chainName];
  if (!chain) {
    error(`Unknown chain: ${chainName}`);
    process.exit(1);
  }

  const addresses = getDeploymentAddresses(chainName);
  if (!addresses) {
    error(`No deployment found for ${chainName}`);
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(chain.rpc);
  const core = new ethers.Contract(addresses.core.address, CORE_ABI, provider);
  const router = new ethers.Contract(addresses.router.address, ROUTER_ABI, provider);

  log("");
  log(`${colors.blue}Contract Status on ${chainName}${colors.reset}`);
  log("─".repeat(70));
  log("");

  const coreStatus = addresses.core.recorded
    ? `${colors.green}deployed${colors.reset}`
    : `${colors.yellow}computed${colors.reset}`;
  log(`${colors.bold}SpritzPayCore${colors.reset} (${addresses.core.address}) [${coreStatus}]`);
  const coreOwner = await core.owner();
  log(`  Owner: ${coreOwner}`);

  const tokens = await core.acceptedPaymentTokens();
  log(`  Payment Tokens: ${tokens.length}`);
  for (const token of tokens) {
    const recipient = await core.paymentRecipient(token);
    let symbol = "";
    try {
      const erc20 = new ethers.Contract(token, ERC20_ABI, provider);
      symbol = await erc20.symbol();
    } catch {
      symbol = "???";
    }
    log(`    ${colors.dim}${token} (${symbol}) → ${recipient}${colors.reset}`);
  }

  log("");
  const routerStatus = addresses.router.recorded
    ? `${colors.green}deployed${colors.reset}`
    : `${colors.yellow}computed${colors.reset}`;
  log(`${colors.bold}SpritzRouter${colors.reset} (${addresses.router.address}) [${routerStatus}]`);
  const routerOwner = await router.owner();
  const swapModule = await router.swapModule();
  log(`  Owner: ${routerOwner}`);
  log(`  Swap Module: ${swapModule}`);

  log("");
}

function printUsage(): void {
  log("");
  log(`${colors.blue}Safe Admin CLI${colors.reset} - Manage Spritz contracts via Safe multisig`);
  log("");
  log(`${colors.bold}Commands:${colors.reset}`);
  log("");
  log(`  ${colors.green}bun safe status${colors.reset}`);
  log(`      Show all deployments across all chains`);
  log("");
  log(`  ${colors.green}bun safe status <chain>${colors.reset}`);
  log(`      Show detailed contract configuration for a specific chain`);
  log("");
  log(`  ${colors.green}bun safe list <chain>${colors.reset}`);
  log(`      List pending Safe transactions`);
  log("");
  log(`  ${colors.green}bun safe sign <chain> <safeTxHash>${colors.reset}`);
  log(`      Sign a pending transaction`);
  log("");
  log(`  ${colors.green}bun safe execute <chain> <safeTxHash>${colors.reset}`);
  log(`      Execute a fully-signed transaction`);
  log("");
  log(`${colors.bold}Propose Actions:${colors.reset}`);
  log("");
  log(`  ${colors.green}bun safe setSwapModule <chain> <moduleAddress>${colors.reset}`);
  log(`      Set the swap module on Router`);
  log("");
  log(`  ${colors.green}bun safe addPaymentToken <chain> <token> <recipient>${colors.reset}`);
  log(`      Add a payment token on Core`);
  log("");
  log(`  ${colors.green}bun safe removePaymentToken <chain> <token>${colors.reset}`);
  log(`      Remove a payment token from Core`);
  log("");
  log(`  ${colors.green}bun safe sweep <chain> <core|router> <token> <to>${colors.reset}`);
  log(`      Sweep tokens from a contract`);
  log("");
  log(`${colors.bold}Examples:${colors.reset}`);
  log(`  ${colors.dim}bun safe status${colors.reset}`);
  log(`  ${colors.dim}bun safe status base${colors.reset}`);
  log(`  ${colors.dim}bun safe setSwapModule base 0x1234...${colors.reset}`);
  log(`  ${colors.dim}bun safe addPaymentToken base 0xUSDC... 0xRecipient...${colors.reset}`);
  log(`  ${colors.dim}bun safe list base${colors.reset}`);
  log(`  ${colors.dim}bun safe sign base 0xsafeTxHash...${colors.reset}`);
  log(`  ${colors.dim}bun safe execute base 0xsafeTxHash...${colors.reset}`);
  log("");
  log(`${colors.bold}Environment:${colors.reset}`);
  log(`  Configure signers in .env (see .env.example)`);
  log(`  RPC_KEY            Alchemy API key`);
  log("");
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") {
    printUsage();
    process.exit(0);
  }

  const command = args[0];

  try {
    switch (command) {
      case "status":
        if (args[1]) {
          await showStatus(args[1]);
        } else {
          await showAllStatus();
        }
        break;

      case "list":
        if (!args[1]) {
          error("Missing chain name");
          process.exit(1);
        }
        await listPendingTransactions(args[1]);
        break;

      case "sign":
        if (!args[1] || !args[2]) {
          error("Usage: bun safe sign <chain> <safeTxHash>");
          process.exit(1);
        }
        await signTransaction(args[1], args[2]);
        break;

      case "execute":
        if (!args[1] || !args[2]) {
          error("Usage: bun safe execute <chain> <safeTxHash>");
          process.exit(1);
        }
        await executeTransaction(args[1], args[2]);
        break;

      case "setSwapModule":
        if (!args[1] || !args[2]) {
          error("Usage: bun safe setSwapModule <chain> <moduleAddress>");
          process.exit(1);
        }
        await setSwapModule(args[1], args[2]);
        break;

      case "addPaymentToken":
        if (!args[1] || !args[2] || !args[3]) {
          error("Usage: bun safe addPaymentToken <chain> <token> <recipient>");
          process.exit(1);
        }
        await addPaymentToken(args[1], args[2], args[3]);
        break;

      case "removePaymentToken":
        if (!args[1] || !args[2]) {
          error("Usage: bun safe removePaymentToken <chain> <token>");
          process.exit(1);
        }
        await removePaymentToken(args[1], args[2]);
        break;

      case "sweep":
        if (!args[1] || !args[2] || !args[3] || !args[4]) {
          error("Usage: bun safe sweep <chain> <core|router> <token> <to>");
          process.exit(1);
        }
        if (args[2] !== "core" && args[2] !== "router") {
          error("Contract must be 'core' or 'router'");
          process.exit(1);
        }
        await sweep(args[1], args[2], args[3], args[4]);
        break;

      default:
        error(`Unknown command: ${command}`);
        printUsage();
        process.exit(1);
    }
  } catch (e) {
    error((e as Error).message);
    if (process.env.DEBUG) {
      console.error(e);
    }
    process.exit(1);
  }
}

main();
