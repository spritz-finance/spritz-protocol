# Spritz Protocol Deployment Guide

This document provides comprehensive instructions for deploying SpritzPayCore and SpritzRouter contracts across multiple EVM chains using deterministic CREATE3 addresses.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Key Management](#key-management)
4. [Deployment Package](#deployment-package)
5. [Deployment Process](#deployment-process)
6. [Contract Verification](#contract-verification)
7. [Post-Deployment Setup](#post-deployment-setup)
8. [Adding New Chains](#adding-new-chains)
9. [Troubleshooting](#troubleshooting)
10. [Security Checklist](#security-checklist)

---

## Overview

### Architecture

```
┌─────────────────┐     ┌─────────────────┐
│  SpritzRouter   │────▶│  SpritzPayCore  │────▶ Payment Recipients
│  (User-facing)  │     │  (Settlement)   │
└─────────────────┘     └─────────────────┘
        │                       │
        ▼                       ▼
   Swap Module            Token Registry
```

### Deployment Strategy

- **CREATE3 via CreateX**: Deterministic addresses across all chains
- **Same deployer + same salt = same address everywhere**
- **Frozen bytecode**: Immutable deployment artifacts committed to git

### Contract Addresses

Once deployed, contracts will have **identical addresses on all chains** when using the same deployer wallet and salt.

| Contract | Salt | Address |
|----------|------|---------|
| SpritzPayCore | `keccak256("spritz.core.v1")` | TBD after first deploy |
| SpritzRouter | `keccak256("spritz.router.v1")` | TBD after first deploy |

---

## Prerequisites

### Required Tools

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify installation
forge --version  # Should show 0.2.0 or higher
cast --version
```

### Environment Setup

Create a `.env` file (never commit this):

```bash
# RPC URLs
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
OPTIMISM_RPC_URL=https://opt-mainnet.g.alchemy.com/v2/YOUR_KEY
POLYGON_RPC_URL=https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY

# Block Explorer API Keys
ETHERSCAN_API_KEY=your_etherscan_key
ARBISCAN_API_KEY=your_arbiscan_key
BASESCAN_API_KEY=your_basescan_key
OPTIMISTIC_ETHERSCAN_API_KEY=your_optimistic_key
POLYGONSCAN_API_KEY=your_polygonscan_key

# Deployment Config
ADMIN_ADDRESS=0xYourMultisigAddress
```

Load environment:

```bash
source .env
```

---

## Key Management

### Option 1: Encrypted Keystore (Recommended)

The most secure option for individual deployers. Private key is encrypted with a password.

```bash
# Import your private key into encrypted keystore
cast wallet import deployer --interactive

# You'll be prompted to:
# 1. Enter your private key
# 2. Set a password (use a strong one!)

# List your keystores
cast wallet list

# The keystore is saved to ~/.foundry/keystores/deployer
```

**Using the keystore:**

```bash
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --account deployer \
  --broadcast

# Enter password when prompted
```

### Option 2: Hardware Wallet (Most Secure)

Best for production mainnet deployments.

```bash
# Ledger
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --ledger \
  --sender 0xYourLedgerAddress \
  --broadcast

# Trezor
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --trezor \
  --sender 0xYourTrezorAddress \
  --broadcast
```

### Option 3: AWS KMS (Best for CI/CD)

For automated deployments in secure environments.

```bash
# Set AWS credentials
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_KMS_KEY_ID=your-kms-key-id

# Deploy using KMS
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --aws \
  --sender 0xYourKMSAddress \
  --broadcast
```

### ⚠️ Option 4: Environment Variable (Testing Only)

**Never use for mainnet!** Key visible in shell history.

```bash
export PRIVATE_KEY=0x...

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

---

## Deployment Package

### Creating a Frozen Package

Before first deployment, create an immutable snapshot of all deployment artifacts:

```bash
# Build and snapshot everything
./script/snapshot-bytecode.sh v1
```

This creates `deployments/v1/` containing:

| File | Purpose |
|------|---------|
| `artifacts/*.initcode` | Bytecode for CREATE3 deployment |
| `artifacts/*.deployed` | Runtime bytecode (for verification) |
| `artifacts/*.json` | Full compiler output |
| `verify/*.standard-json-input.json` | Etherscan verification payload |
| `src/` | Source code snapshot |
| `foundry.toml` | Compiler settings |
| `metadata.json` | Build info, git commit |
| `checksums.sha256` | SHA256 integrity hashes |

### Commit the Package

```bash
git add deployments/v1/
git commit -m "Freeze v1 deployment artifacts"
git push
```

### Verifying Package Integrity

Before deploying to a new chain, verify bytecode matches:

```bash
# Rebuild
forge build --force

# Compare checksums
cd deployments/v1
shasum -c checksums.sha256
```

---

## Deployment Process

### Step 1: Preview Addresses

Before deploying, preview what addresses will be generated:

```bash
export ADMIN_ADDRESS=0xYourMultisig

forge script script/Deploy.s.sol:DeploySpritzPreview \
  --rpc-url $SEPOLIA_RPC_URL
```

Output:
```
=== Address Preview ===
Deployer: 0x...
With current deployer, contracts will be at:
  Core: 0x...
  Router: 0x...

NOTE: Same deployer + same salt = same address on ALL chains
```

### Step 2: Deploy to Testnet

Always test on Sepolia first:

```bash
export ADMIN_ADDRESS=0xYourTestMultisig

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --account deployer \
  --broadcast \
  --verify
```

### Step 3: Verify Testnet Deployment

1. Check deployment succeeded in console output
2. Verify on [Sepolia Etherscan](https://sepolia.etherscan.io)
3. Test basic functions:

```bash
# Check owner
cast call $CORE_ADDRESS "owner()(address)" --rpc-url $SEPOLIA_RPC_URL

# Check router's core reference
cast call $ROUTER_ADDRESS "core()(address)" --rpc-url $SEPOLIA_RPC_URL
```

### Step 4: Deploy to Mainnet

```bash
# Use your PRODUCTION multisig!
export ADMIN_ADDRESS=0xYourProductionMultisig

# Deploy with hardware wallet for maximum security
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --ledger \
  --sender 0xYourLedgerAddress \
  --broadcast \
  --verify \
  --slow  # Wait for confirmations
```

### Step 5: Record Deployment

After successful deployment, record the addresses:

```bash
# Add to deployments/v1/addresses.json
{
  "sepolia": {
    "chainId": 11155111,
    "core": "0x...",
    "router": "0x...",
    "deployedAt": "2024-XX-XX",
    "deployer": "0x...",
    "txHash": "0x..."
  },
  "mainnet": {
    "chainId": 1,
    "core": "0x...",
    "router": "0x...",
    "deployedAt": "2024-XX-XX",
    "deployer": "0x...",
    "txHash": "0x..."
  }
}
```

---

## Contract Verification

### Automatic Verification

The `--verify` flag attempts automatic verification:

```bash
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --account deployer \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Manual Verification (if automatic fails)

#### Using Forge CLI:

```bash
# SpritzPayCore (no constructor args)
forge verify-contract \
  --chain mainnet \
  --watch \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  0xCORE_ADDRESS \
  src/SpritzPayCore.sol:SpritzPayCore

# SpritzRouter (constructor arg: core address)
forge verify-contract \
  --chain mainnet \
  --watch \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address)" 0xCORE_ADDRESS) \
  0xROUTER_ADDRESS \
  src/SpritzRouter.sol:SpritzRouter
```

#### Using Standard JSON Input:

1. Go to Etherscan → Contract → Verify & Publish
2. Select "Solidity (Standard-Json-Input)"
3. Upload `deployments/v1/verify/SpritzPayCore.standard-json-input.json`
4. Enter constructor arguments if required

### Generate Standard JSON Input

```bash
forge verify-contract \
  --show-standard-json-input \
  0x0000000000000000000000000000000000000000 \
  src/SpritzPayCore.sol:SpritzPayCore \
  > standard-input.json
```

---

## Post-Deployment Setup

After deployment, the admin (multisig) must configure the contracts:

### 1. Add Payment Tokens

```bash
# From your multisig, call:
cast send $CORE_ADDRESS \
  "addPaymentToken(address,address)" \
  $USDC_ADDRESS \
  $TREASURY_ADDRESS \
  --rpc-url $MAINNET_RPC_URL \
  --account deployer
```

Or via multisig UI, call `addPaymentToken(token, recipient)` on SpritzPayCore.

### 2. Set Swap Module

```bash
cast send $ROUTER_ADDRESS \
  "setSwapModule(address)" \
  $SWAP_MODULE_ADDRESS \
  --rpc-url $MAINNET_RPC_URL \
  --account deployer
```

### 3. Transfer Ownership to Multisig

If you deployed with an EOA and need to transfer to multisig:

```bash
# Transfer Core ownership
cast send $CORE_ADDRESS \
  "transferOwnership(address)" \
  $MULTISIG_ADDRESS \
  --rpc-url $MAINNET_RPC_URL \
  --account deployer

# Transfer Router ownership
cast send $ROUTER_ADDRESS \
  "transferOwnership(address)" \
  $MULTISIG_ADDRESS \
  --rpc-url $MAINNET_RPC_URL \
  --account deployer
```

---

## Adding New Chains

To deploy to a new chain with the same addresses:

### 1. Verify CreateX is Deployed

CreateX must exist at `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`.

Check: https://github.com/pcaversaccio/createx#deployments

### 2. Add RPC and Explorer Config

Update `foundry.toml`:

```toml
[rpc_endpoints]
newchain = "${NEWCHAIN_RPC_URL}"

[etherscan]
newchain = { key = "${NEWCHAIN_API_KEY}", url = "https://api.newchainscan.io/api" }
```

### 3. Deploy with Same Deployer

**Critical**: Use the exact same deployer address!

```bash
forge script script/Deploy.s.sol \
  --rpc-url $NEWCHAIN_RPC_URL \
  --account deployer \
  --broadcast \
  --verify
```

### 4. Verify Same Addresses

```bash
# Should match addresses from other chains
forge script script/Deploy.s.sol:DeploySpritzPreview \
  --rpc-url $NEWCHAIN_RPC_URL
```

---

## Troubleshooting

### "Core address mismatch!"

**Cause**: Different deployer address than expected.

**Fix**: CREATE3 addresses depend on `deployer + salt`. Use the same deployer wallet on all chains.

### "Already initialized"

**Cause**: Running deploy script twice on same chain.

**Fix**: This is expected. Contracts can only be initialized once.

### Verification fails

1. Ensure compiler settings match exactly:
   ```bash
   cat deployments/v1/foundry.toml
   ```

2. Wait 1-2 minutes after deployment for propagation

3. Try manual verification with standard JSON input

### "Nonce too low"

**Cause**: Transaction already mined or stuck.

**Fix**:
```bash
# Check current nonce
cast nonce 0xYourAddress --rpc-url $RPC_URL

# If stuck, speed up or cancel pending tx
```

### Gas estimation fails

**Cause**: Usually insufficient funds or contract revert.

**Fix**:
```bash
# Check balance
cast balance 0xYourAddress --rpc-url $RPC_URL

# Simulate deployment
forge script script/Deploy.s.sol --rpc-url $RPC_URL
# (without --broadcast)
```

---

## Security Checklist

### Pre-Deployment

- [ ] Contracts audited by reputable firm
- [ ] All tests passing (`forge test`)
- [ ] 100% code coverage (`forge coverage`)
- [ ] Static analysis clean (`slither .`)
- [ ] Deployment package frozen and committed
- [ ] Admin address is a multisig (NOT an EOA)
- [ ] Testnet deployment successful
- [ ] Testnet verification successful

### Deployment

- [ ] Using hardware wallet or encrypted keystore
- [ ] Private key never exposed in shell history
- [ ] Correct network selected (double-check chain ID)
- [ ] Gas price reasonable for network conditions
- [ ] Admin address confirmed correct

### Post-Deployment

- [ ] Contract addresses recorded
- [ ] Contracts verified on block explorer
- [ ] Ownership transferred to multisig (if needed)
- [ ] Payment tokens configured
- [ ] Swap module set (if using swaps)
- [ ] Basic functionality tested on mainnet

### Ongoing

- [ ] Monitor for unusual activity
- [ ] Keep deployment artifacts backed up
- [ ] Document any configuration changes

---

## Quick Reference

### Common Commands

```bash
# Preview addresses
forge script script/Deploy.s.sol:DeploySpritzPreview --rpc-url $RPC_URL

# Deploy with keystore
forge script script/Deploy.s.sol --rpc-url $RPC_URL --account deployer --broadcast --verify

# Deploy with Ledger
forge script script/Deploy.s.sol --rpc-url $RPC_URL --ledger --broadcast --verify

# Verify contract
forge verify-contract --chain mainnet $ADDRESS src/Contract.sol:Contract

# Check owner
cast call $ADDRESS "owner()(address)" --rpc-url $RPC_URL

# Transfer ownership
cast send $ADDRESS "transferOwnership(address)" $NEW_OWNER --rpc-url $RPC_URL --account deployer
```

### CreateX Address

```
0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
```

Deployed on: Ethereum, Arbitrum, Optimism, Base, Polygon, BSC, Avalanche, Fantom, Gnosis, and 30+ other chains.

### Salts

```solidity
CORE_SALT = keccak256("spritz.core.v1")   // 0x...
ROUTER_SALT = keccak256("spritz.router.v1") // 0x...
```

---

## Support

- GitHub Issues: [spritz-protocol/issues](https://github.com/spritz-finance/spritz-protocol/issues)
- Documentation: [docs.spritz.finance](https://docs.spritz.finance)
