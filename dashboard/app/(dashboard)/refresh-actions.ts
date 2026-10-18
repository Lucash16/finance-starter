"use server"

import { requireOwner } from "@/lib/require-owner"
import { parseRefreshResponse, type RefreshResult } from "@/lib/manual-refresh"

export async function refreshBanks(): Promise<RefreshResult> {
  await requireOwner()
  const url = process.env.FINANCE_SYNC_URL
  const token = process.env.FINANCE_SYNC_TOKEN
  if (!url || !token) return { status: "error", items: [], message: "Atualização indisponível. Verifique a configuração da sincronização." }
  try {
    const endpoint = new URL(url)
    endpoint.searchParams.set("mode", "update")
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
      cache: "no-store",
      signal: AbortSignal.timeout(165_000),
    })
    if (response.status !== 200 && response.status !== 202) {
      return { status: "error", items: [], message: response.status === 401 ? "Sincronização não autorizada. Verifique a configuração." : "Serviço de sincronização indisponível. Tente novamente." }
    }
    return parseRefreshResponse(await response.json(), response.status, token)
  } catch (error) {
    const timedOut = error instanceof Error && ["TimeoutError", "AbortError"].includes(error.name)
    return { status: "error", items: [], message: timedOut ? "A atualização demorou mais que o esperado e pode continuar no banco. Consulte Sincronização antes de tentar novamente." : "Não foi possível atualizar os bancos. Tente novamente." }
  }
}
