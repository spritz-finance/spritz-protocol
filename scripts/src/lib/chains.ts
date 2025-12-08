/**
 * Chain utilities - build runtime chain objects with resolved values
 */

import type { Config, ChainConfig } from "./config";

export interface Chain {
  name: string;
  chainId: number;
  rpc: string;
  explorer: string;
  etherscanApi?: string;
  safeService?: string;
  admin: string;
  testnet: boolean;
}

export function buildChains(
  config: Config,
  rpcKey: string
): Record<string, Chain> {
  const chains: Record<string, Chain> = {};

  for (const [name, chainConfig] of Object.entries(config.chains)) {
    const rpc = chainConfig.rpc.replace("${RPC_KEY}", rpcKey);
    chains[name] = {
      name,
      chainId: chainConfig.chainId,
      rpc,
      explorer: chainConfig.explorer,
      etherscanApi: chainConfig.etherscanApi,
      safeService: chainConfig.safeService,
      admin: config.admin.safe,
      testnet: chainConfig.testnet ?? false,
    };
  }

  return chains;
}

export function getChain(
  chains: Record<string, Chain>,
  name: string
): Chain | null {
  return chains[name] ?? null;
}

export function listChainNames(chains: Record<string, Chain>): {
  mainnets: string[];
  testnets: string[];
} {
  const mainnets: string[] = [];
  const testnets: string[] = [];

  for (const [name, chain] of Object.entries(chains)) {
    if (chain.testnet) {
      testnets.push(name);
    } else {
      mainnets.push(name);
    }
  }

  return { mainnets, testnets };
}
