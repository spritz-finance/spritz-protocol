const OPENOCEAN_API_BASE = "https://open-api.openocean.finance/v4"

const CHAIN_NAMES: Record<number, string> = {
  1: "eth",
  8453: "base",
  42161: "arbitrum",
  10: "optimism",
  137: "polygon",
  43114: "avax",
  56: "bsc",
}

export type OpenOceanSwapParams = {
  chainId: number
  inTokenAddress: string
  outTokenAddress: string
  amount: string
  account: string
  slippage?: number
  gasPrice?: string
}

export type OpenOceanSwapResponse = {
  code: number
  data: {
    inToken: { address: string; decimals: number; symbol: string }
    outToken: { address: string; decimals: number; symbol: string }
    inAmount: string
    outAmount: string
    estimatedGas: string
    to: string
    data: string
    value: string
  }
}

export type OpenOceanReverseQuoteParams = {
  chainId: number
  inTokenAddress: string
  outTokenAddress: string
  amount: string
  gasPrice?: string
}

export type OpenOceanReverseQuoteResponse = {
  code: number
  data: {
    inToken: { address: string; decimals: number; symbol: string }
    outToken: { address: string; decimals: number; symbol: string }
    inAmount: string
    outAmount: string
  }
}

function getChainName(chainId: number): string {
  const name = CHAIN_NAMES[chainId]
  if (!name) throw new Error(`Unsupported chain ID: ${chainId}`)
  return name
}

export async function getOpenOceanSwap(
  params: OpenOceanSwapParams
): Promise<OpenOceanSwapResponse> {
  const chainName = getChainName(params.chainId)

  const gasPriceGwei = params.gasPrice ?? "5"
  const gasPriceWei = BigInt(Math.floor(parseFloat(gasPriceGwei) * 1e9)).toString()

  const queryParams = new URLSearchParams({
    inTokenAddress: params.inTokenAddress,
    outTokenAddress: params.outTokenAddress,
    amountDecimals: params.amount,
    account: params.account,
    gasPriceDecimals: gasPriceWei,
    slippage: (params.slippage ?? 1).toString(),
  })

  const url = `${OPENOCEAN_API_BASE}/${chainName}/swap?${queryParams.toString()}`

  const response = await fetch(url)
  if (!response.ok) {
    const text = await response.text()
    throw new Error(`OpenOcean API error: ${response.status} - ${text}`)
  }

  const data: OpenOceanSwapResponse = await response.json()
  if (data.code !== 200) {
    throw new Error(`OpenOcean API error code: ${data.code}`)
  }

  return data
}

export async function getOpenOceanReverseQuote(
  params: OpenOceanReverseQuoteParams
): Promise<OpenOceanReverseQuoteResponse> {
  const chainName = getChainName(params.chainId)

  const queryParams = new URLSearchParams({
    inTokenAddress: params.inTokenAddress,
    outTokenAddress: params.outTokenAddress,
    amount: params.amount,
    gasPrice: params.gasPrice ?? "5",
  })

  const url = `${OPENOCEAN_API_BASE}/${chainName}/reverseQuote?${queryParams.toString()}`

  const response = await fetch(url)
  if (!response.ok) {
    const text = await response.text()
    throw new Error(`OpenOcean API error: ${response.status} - ${text}`)
  }

  const data: OpenOceanReverseQuoteResponse = await response.json()
  if (data.code !== 200) {
    throw new Error(`OpenOcean API error code: ${data.code}`)
  }

  return data
}
