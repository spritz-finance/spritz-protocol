#!/usr/bin/env bun
/**
 * FFI script for Foundry fork tests to get real swap calldata from aggregator APIs.
 *
 * Usage:
 *   bun scripts/src/get-swap.ts openocean <chainId> <inToken> <outToken> <amount> <account>
 *   bun scripts/src/get-swap.ts openocean-reverse <chainId> <inToken> <outToken> <outAmount>
 *   bun scripts/src/get-swap.ts paraswap <chainId> <inToken> <inDecimals> <outToken> <outDecimals> <amount> <side> <account>
 *
 * Output: JSON with swap data that can be parsed by vm.parseJson in Solidity
 */

import { getOpenOceanSwap, getOpenOceanReverseQuote } from "./lib/openocean"
import { getParaSwapSwap } from "./lib/paraswap"
import { ethers } from "ethers"

async function main() {
  const [command, ...args] = process.argv.slice(2)

  try {
    let result: unknown

    switch (command) {
      case "openocean": {
        const [chainId, inToken, outToken, amount, account] = args
        const swap = await getOpenOceanSwap({
          chainId: parseInt(chainId),
          inTokenAddress: inToken,
          outTokenAddress: outToken,
          amount,
          account,
          slippage: 3, // 3% slippage for tests
        })

        // Encode swapData as (bytes callData, address target)
        const swapData = ethers.AbiCoder.defaultAbiCoder().encode(
          ["bytes", "address"],
          [swap.data.data, swap.data.to]
        )

        result = {
          success: true,
          swapData,
          target: swap.data.to,
          inAmount: swap.data.inAmount,
          outAmount: swap.data.outAmount,
          value: swap.data.value,
        }
        break
      }

      case "openocean-reverse": {
        const [chainId, inToken, outToken, outAmount] = args
        const quote = await getOpenOceanReverseQuote({
          chainId: parseInt(chainId),
          inTokenAddress: inToken,
          outTokenAddress: outToken,
          amount: outAmount,
        })

        result = {
          success: true,
          inAmount: quote.data.inAmount,
          outAmount: quote.data.outAmount,
        }
        break
      }

      case "paraswap": {
        const [chainId, srcToken, srcDecimals, destToken, destDecimals, amount, side, account] =
          args
        const { priceRoute, tx } = await getParaSwapSwap({
          chainId: parseInt(chainId),
          srcToken,
          srcDecimals: parseInt(srcDecimals),
          destToken,
          destDecimals: parseInt(destDecimals),
          amount,
          side: side as "SELL" | "BUY",
          userAddress: account,
        })

        // Encode swapData as (bytes callData, address target)
        const swapData = ethers.AbiCoder.defaultAbiCoder().encode(
          ["bytes", "address"],
          [tx.data, tx.to]
        )

        result = {
          success: true,
          swapData,
          target: tx.to,
          srcAmount: priceRoute.srcAmount,
          destAmount: priceRoute.destAmount,
          value: tx.value,
          tokenTransferProxy: priceRoute.tokenTransferProxy,
        }
        break
      }

      default:
        result = { success: false, error: `Unknown command: ${command}` }
    }

    console.log(JSON.stringify(result))
  } catch (e) {
    const error = e instanceof Error ? e.message : String(e)
    console.log(JSON.stringify({ success: false, error }))
    process.exit(1)
  }
}

main()
