"use client"

import { useEffect, useState } from "react"
import { useRouter } from "next/navigation"
import { refreshBanks } from "@/app/(dashboard)/refresh-actions"
import { IconSync } from "@/components/icons"
import type { RefreshResult } from "@/lib/manual-refresh"

export function NavRefreshFab() {
  const router = useRouter()
  const [pending, setPending] = useState(false)
  const [result, setResult] = useState<RefreshResult | null>(null)

  useEffect(() => {
    if (result?.status !== "ok") return
    const timer = setTimeout(() => setResult(null), 4500)
    return () => clearTimeout(timer)
  }, [result])

  async function refresh() {
    if (pending) return
    setPending(true)
    setResult(null)
    try {
      const next = await refreshBanks()
      setResult(next)
      if (["ok", "partial", "accepted"].includes(next.status)) router.refresh()
    } catch {
      setResult({ status: "error", items: [], message: "Não foi possível atualizar. Verifique sua conexão e tente novamente." })
    } finally {
      setPending(false)
    }
  }

  return <>
    <button type="button" className="navFab" disabled={pending} onClick={refresh} aria-label="Atualizar bancos" aria-busy={pending}>
      <IconSync className={pending ? "navRefreshSpin" : undefined} />
    </button>
    <p className="navRefreshToast" role="status" aria-live="polite" aria-atomic="true">
      {pending ? "Atualizando bancos…" : result?.status === "ok" ? "Pronto" : result?.message}
    </p>
  </>
}
