# Spritz Protocol

Payment infrastructure for crypto-to-fiat payments with optional token swaps.

## Contracts

- **SpritzPayCore**: Core payment processing with token allowlisting and recipient management
- **SpritzRouter**: Payment router with swap support via pluggable swap modules
- **OpenOceanModule**: Swap module for OpenOcean DEX aggregator
- **ParaSwapModule**: Swap module for ParaSwap DEX aggregator

## Deterministic Deployment

Contracts are deployed via [CreateX](https://github.com/pcaversaccio/createx) using CREATE3 for identical addresses across all chains.

### Deployed Addresses

| Contract | Address |
|----------|---------|
| SpritzPayCore | `0x000000000012F55170d4A2aB5ace512Eeb925Dca` |
| SpritzRouter | `0x0A2d7D9BFE42D5146Af53dce8ef4956F148C2a5F` |

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Bun](https://bun.sh) (for deployment scripts)
- [1Password CLI](https://developer.1password.com/docs/cli) (for production deployments)

### Build

```bash
forge build
```

### Test

```bash
forge test
```

---

# Deployment System

The deployment system provides deterministic, reproducible deployments across multiple chains with frozen bytecode verification.

## Quick Start

```bash
# 1. Freeze contract bytecode
bun freeze SpritzPayCore

# 2. Generate a vanity salt (optional)
bun salt SpritzPayCore

# 3. Add salt to config.json
# 4. Deploy (simulation)
bun deployment SpritzPayCore base

# 5. Deploy (for real)
bun deployment SpritzPayCore base --broadcast

# 6. Verify on block explorer
bun deployment --verify SpritzPayCore base
```

## Architecture Overview

```
config.json          <- Central configuration (salts, chains, addresses)
    │
    ├── contracts    <- Contract definitions with salts and constructor args
    │   ├── SpritzPayCore (no args)
    │   ├── SpritzRouter (args: ["SpritzPayCore"])
    │   └── OpenOceanModule (args: ["${chain.openOcean}", "${chain.weth}"])
    │
    └── chains       <- Chain configurations with RPC, explorer, and addresses
        ├── ethereum (addresses: weth, openOcean, paraSwapRegistry)
        ├── base
        └── ...

deployments/         <- Frozen bytecode packages
    ├── SpritzPayCore/
    │   ├── artifacts/     <- Compiled bytecode
    │   ├── src/           <- Source snapshot
    │   ├── verify/        <- Etherscan verification
    │   └── metadata.json  <- Initcode hash, deployment records
    └── SpritzRouter/
        └── ...
```

## Configuration

### config.json Structure

```json
{
  "admin": {
    "safe": "0x...",           // Multisig that owns deployed contracts
    "threshold": 2
  },
  "deployer": {
    "address": "0x...",        // EOA that deploys contracts
    "keyRef": "op://..."       // 1Password reference for private key
  },
  "contracts": {
    "SpritzPayCore": {
      "salt": "0x..."          // CREATE3 salt (determines address)
    },
    "SpritzRouter": {
      "salt": "0x...",
      "args": ["SpritzPayCore"]  // References another contract
    },
    "OpenOceanModule": {
      "salt": "0x...",
      "args": ["${chain.openOcean}", "${chain.weth}"]  // Chain-specific
    }
  },
  "chains": {
    "base": {
      "chainId": 8453,
      "rpc": "https://...",
      "addresses": {           // Chain-specific addresses
        "weth": "0x4200000000000000000000000000000000000006",
        "openOcean": "0x6352a56caadC4F1E25CD6c75970Fa768A3304e64"
      }
    }
  }
}
```

### Constructor Argument Types

The deployment system supports three types of constructor arguments:

| Type | Example | Resolution |
|------|---------|------------|
| Contract reference | `"SpritzPayCore"` | Resolved to deployed CREATE3 address |
| Chain-specific | `"${chain.weth}"` | Resolved from chain's `addresses` config |
| Literal value | `"0x123..."` | Passed through unchanged |

### Contract Categories

**Universal contracts** (same address everywhere):
- No constructor args OR args are only contract references
- Examples: `SpritzPayCore`, `SpritzRouter`

**Chain-specific contracts** (same address, different bytecode):
- Constructor args include `${chain.*}` references
- Examples: `OpenOceanModule`, `ParaSwapModule`

## Freezing Contracts

Frozen bytecode packages ensure identical deployments across all chains.

### Freeze a Contract

```bash
bun freeze SpritzPayCore
```

Creates `deployments/SpritzPayCore/` containing:
- `artifacts/*.initcode` - Deployment bytecode
- `artifacts/*.deployed` - Runtime bytecode
- `artifacts/*.json` - Full compiler output
- `verify/standard-json-input.json` - Etherscan verification
- `src/` - Source code snapshot
- `foundry.toml` - Compiler settings
- `metadata.json` - Build metadata with initcode hash
- `checksums.sha256` - File checksums

### List Frozen Contracts

```bash
bun freeze --list
```

### Delete and Re-freeze

```bash
bun freeze --delete SpritzPayCore
bun freeze SpritzPayCore
```

### Compiler Settings

The `foundry.toml` is configured for reproducible builds:

```toml
solc = "0.8.30"
evm_version = "cancun"
optimizer = true
optimizer_runs = 10_000_000
cbor_metadata = false      # Disables metadata hash
bytecode_hash = "none"     # Ensures identical bytecode
```

**Do not change these settings after deployment begins.**

## Generating Salts

### Using createXcrunch (Vanity Addresses)

Mine CREATE3 salts for vanity addresses:

```bash
./createXcrunch create3 \
  --caller 0xYourDeployerAddress \
  --matching badface
```

**Important**: Do NOT use the `--crosschain` flag. Omitting it produces salts with `0x00` in byte 21, giving the same address on all chains.

Salt format: `[deployer (20 bytes)][0x00][entropy (11 bytes)]`

### Using the Salt Script

```bash
bun salt SpritzPayCore
```

Generates a random salt with proper format for the configured deployer.

## Deployment Commands

### Show Contract Address

```bash
# Universal contract
bun deployment --address SpritzPayCore

# Chain-specific contract (requires chain name)
bun deployment --address OpenOceanModule base
```

### List All Contracts

```bash
bun deployment --list
```

Shows deployment order, dependencies, frozen status, and deployed chains.

### List Available Chains

```bash
bun deployment --chains
```

### Simulate Deployment

```bash
bun deployment SpritzPayCore base
```

Runs pre-flight checks:
- Verifies frozen bytecode exists and matches hash
- Checks dependencies are deployed
- Tests RPC connection
- Shows deployment plan

### Deploy for Real

```bash
bun deployment SpritzPayCore base --broadcast
```

Requires 1Password CLI signed in. Includes:
- All pre-flight checks
- Deployer address verification from 1Password
- Mainnet warning with 10-second countdown
- Bytecode verification after deployment
- Deployment record in metadata.json

### Record Existing Deployment

```bash
bun deployment --record SpritzPayCore base
```

Records a deployment that was made manually or by another tool.

### Verify on Block Explorer

```bash
bun deployment --verify SpritzPayCore base
```

## Adding a New Contract

### 1. Write the Contract

```solidity
// src/MyNewContract.sol
contract MyNewContract {
    constructor(address dependency) { ... }
}
```

### 2. Freeze the Bytecode

```bash
bun freeze MyNewContract
```

### 3. Generate a Salt

```bash
bun salt MyNewContract
```

### 4. Add to config.json

```json
{
  "contracts": {
    "MyNewContract": {
      "salt": "0x...",
      "args": ["SpritzPayCore"]
    }
  }
}
```

### 5. Deploy

```bash
bun deployment MyNewContract base --broadcast
```

## Adding a Chain-Specific Contract

For contracts with chain-dependent constructor args (e.g., swap modules):

### 1. Add Contract with Chain References

```json
{
  "contracts": {
    "MySwapModule": {
      "salt": "0x...",
      "args": ["${chain.dexRouter}", "${chain.weth}"]
    }
  }
}
```

### 2. Add Addresses to Each Chain

```json
{
  "chains": {
    "base": {
      "addresses": {
        "weth": "0x4200000000000000000000000000000000000006",
        "dexRouter": "0x..."
      }
    },
    "ethereum": {
      "addresses": {
        "weth": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "dexRouter": "0x..."
      }
    }
  }
}
```

### 3. Deploy to Each Chain

```bash
bun deployment MySwapModule base --broadcast
bun deployment MySwapModule ethereum --broadcast
```

Note: The deployed address will be the same on all chains, but the constructor args (and thus runtime bytecode) will differ.

## Adding a New Chain

### 1. Add Chain Configuration

```json
{
  "chains": {
    "newchain": {
      "chainId": 12345,
      "rpc": "https://rpc.newchain.io/v2/${RPC_KEY}",
      "safeService": "https://safe-transaction-newchain.safe.global",
      "explorer": "https://explorer.newchain.io",
      "etherscanApi": "https://api.explorer.newchain.io/api",
      "addresses": {
        "weth": "0x...",
        "openOcean": "0x...",
        "paraSwapRegistry": "0x..."
      }
    }
  }
}
```

### 2. Deploy Contracts

```bash
bun deployment SpritzPayCore newchain --broadcast
bun deployment SpritzRouter newchain --broadcast
bun deployment OpenOceanModule newchain --broadcast
```

## Environment Variables

Create a `.env` file:

```bash
RPC_KEY=your-alchemy-key
ETHERSCAN_API_KEY=your-etherscan-key
```

For local testing with different deployer:

```bash
DEPLOYER_ADDRESS=0x... bun deployment --list
```

## Post-Deployment Setup

After deploying core contracts:

1. **Add payment tokens**: `core.addPaymentToken(token, recipient)`
2. **Set swap module**: `router.setSwapModule(swapModuleAddress)`

## Troubleshooting

### "Contract not frozen"

Run `bun freeze ContractName` first.

### "Salt deployer doesn't match"

The salt was generated for a different deployer address. Either:
- Generate a new salt with `bun salt ContractName`
- Set `DEPLOYER_ADDRESS` to match the salt

### "Chain does not have address configured"

For chain-specific contracts, add the missing address to `chains.<chain>.addresses` in config.json.

### "Dependency not deployed"

Deploy dependencies first. Use `bun deployment --list` to see deployment order.

## License

MIT
