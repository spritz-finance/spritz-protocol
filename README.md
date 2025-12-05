# Spritz Protocol

Payment infrastructure for crypto-to-fiat payments with optional token swaps.

## Contracts

- **SpritzPayCore**: Core payment processing with token allowlisting and recipient management
- **SpritzRouter**: Payment router with swap support via pluggable swap modules

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
- Node.js

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Test Deployment (Fork)

Simulate deployment on a forked chain without needing a private key:

```bash
ADMIN_ADDRESS=0xYourAdmin forge script script/Deploy.s.sol:DeploySpritzForkTest --rpc-url https://eth.llamarpc.com
```

## Freezing Contracts for Deployment

Frozen bytecode packages ensure identical deployments across all chains. Each contract has its own frozen package in `deployments/<ContractName>/`.

### Freeze a Contract

```bash
node scripts/freeze.js SpritzPayCore
```

This creates `deployments/SpritzPayCore/` containing:
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
node scripts/freeze.js --list
```

### Delete a Frozen Build

To re-freeze after changes:

```bash
node scripts/freeze.js --delete SpritzPayCore
node scripts/freeze.js SpritzPayCore
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

Do not change these settings after deployment begins.

## Generating Vanity Salts

Mine CREATE3 salts for vanity addresses using [createXcrunch](https://github.com/HrikB/createXcrunch):

```bash
./createXcrunch create3 \
  --caller 0xYourDeployerAddress \
  --matching badface
```

**Important**: Do NOT use the `--crosschain` flag. Omitting it produces salts with `0x00` in byte 21, giving the same address on all chains.

Salt format: `[deployer (20 bytes)][0x00][entropy (11 bytes)]`

## Production Deployment

### Update Deploy Script

Add salts and initcode hashes to `script/Deploy.s.sol`:

```solidity
bytes32 public constant CORE_SALT = 0x...;
bytes32 public constant ROUTER_SALT = 0x...;
bytes32 public constant CORE_INITCODE_HASH = 0x...;  // from metadata.json
bytes32 public constant ROUTER_INITCODE_HASH = 0x...;
```

### Using Encrypted Keystore

```bash
# Import your key (one-time setup)
cast wallet import deployer --interactive

# Deploy
ADMIN_ADDRESS=0xYourAdmin forge script script/Deploy.s.sol:DeploySpritz \
  --rpc-url $RPC_URL \
  --account deployer \
  --broadcast
```

### Using Ledger

```bash
ADMIN_ADDRESS=0xYourAdmin forge script script/Deploy.s.sol:DeploySpritz \
  --rpc-url $RPC_URL \
  --ledger \
  --broadcast
```

## Contract Verification

After deployment, verify using the standard JSON input files in `deployments/<ContractName>/verify/`:

```bash
forge verify-contract <DEPLOYED_ADDRESS> SpritzPayCore \
  --chain-id <CHAIN_ID> \
  --verifier-url <EXPLORER_API_URL> \
  --verifier etherscan
```

## Post-Deployment Setup

1. **Add payment tokens**: `core.addPaymentToken(token, recipient)`
2. **Set swap module**: `router.setSwapModule(swapModuleAddress)`

## License

MIT
