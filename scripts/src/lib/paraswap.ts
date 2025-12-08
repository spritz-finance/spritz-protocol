const PARASWAP_API_URL = "https://api.paraswap.io"
const PARTNER = "spritzfinance"

export type ParaSwapRateParams = {
  chainId: number
  srcToken: string
  srcDecimals: number
  destToken: string
  destDecimals: number
  amount: string
  side: "SELL" | "BUY"
  userAddress: string
}

export type PriceRoute = {
  blockNumber: number
  network: number
  srcToken: string
  srcDecimals: number
  srcAmount: string
  destToken: string
  destDecimals: number
  destAmount: string
  bestRoute: unknown[]
  gasCostUSD: string
  gasCost: string
  side: string
  tokenTransferProxy: string
  contractAddress: string
  contractMethod: string
  srcUSD: string
  destUSD: string
  partner: string
  partnerFee: number
  maxImpactReached: boolean
  hmac: string
}

export type ParaSwapBuildTxParams = {
  chainId: number
  srcToken: string
  srcDecimals: number
  destToken: string
  destDecimals: number
  srcAmount: string
  destAmount: string
  priceRoute: PriceRoute
  userAddress: string
  deadline?: number
}

export type ParaSwapTxResponse = {
  from: string
  to: string
  value: string
  data: string
  gasPrice: string
  chainId: number
}

export async function getParaSwapRate(params: ParaSwapRateParams): Promise<PriceRoute> {
  const queryParams = new URLSearchParams({
    srcToken: params.srcToken,
    srcDecimals: params.srcDecimals.toString(),
    destToken: params.destToken,
    destDecimals: params.destDecimals.toString(),
    amount: params.amount,
    side: params.side,
    network: params.chainId.toString(),
    userAddress: params.userAddress,
    partner: PARTNER,
  })

  const url = `${PARASWAP_API_URL}/prices?${queryParams.toString()}`

  const response = await fetch(url)
  if (!response.ok) {
    const text = await response.text()
    throw new Error(`ParaSwap prices API error: ${response.status} - ${text}`)
  }

  const data = await response.json()
  return data.priceRoute
}

export async function buildParaSwapTx(
  params: ParaSwapBuildTxParams
): Promise<ParaSwapTxResponse> {
  const url = `${PARASWAP_API_URL}/transactions/${params.chainId}?ignoreChecks=true`

  const body = {
    srcToken: params.srcToken,
    srcDecimals: params.srcDecimals,
    destToken: params.destToken,
    destDecimals: params.destDecimals,
    srcAmount: params.srcAmount,
    destAmount: params.destAmount,
    priceRoute: params.priceRoute,
    userAddress: params.userAddress,
    deadline: params.deadline ?? Math.floor(Date.now() / 1000) + 300,
    partner: PARTNER,
  }

  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })

  if (!response.ok) {
    const text = await response.text()
    throw new Error(`ParaSwap build tx API error: ${response.status} - ${text}`)
  }

  return response.json()
}

export type ParaSwapSwapParams = {
  chainId: number
  srcToken: string
  srcDecimals: number
  destToken: string
  destDecimals: number
  amount: string
  side: "SELL" | "BUY"
  userAddress: string
}

export async function getParaSwapSwap(
  params: ParaSwapSwapParams
): Promise<{ priceRoute: PriceRoute; tx: ParaSwapTxResponse }> {
  const priceRoute = await getParaSwapRate(params)

  const tx = await buildParaSwapTx({
    chainId: params.chainId,
    srcToken: params.srcToken,
    srcDecimals: params.srcDecimals,
    destToken: params.destToken,
    destDecimals: params.destDecimals,
    srcAmount: priceRoute.srcAmount,
    destAmount: priceRoute.destAmount,
    priceRoute,
    userAddress: params.userAddress,
  })

  return { priceRoute, tx }
}
