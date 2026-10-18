import { z } from "zod"

const itemSchema = z.object({
  itemId: z.string(),
  institution: z.string(),
  pluggyStatus: z.string(),
  syncStatus: z.string(),
  message: z.string().optional(),
})
const responseSchema = z.object({
  mode: z.literal("update"),
  ok: z.boolean().optional(),
  accepted: z.boolean().optional(),
  items: z.array(itemSchema),
  finishedAt: z.string().optional(),
})
export type RefreshResult = {
  status: "ok" | "partial" | "accepted" | "error"
  items: z.infer<typeof itemSchema>[]
  message: string
  finishedAt?: string
}

export function parseRefreshResponse(body: unknown, httpStatus: number, token: string): RefreshResult {
  const parsed = responseSchema.safeParse(body)
  if (!parsed.success || (httpStatus === 202 ? parsed.data.accepted !== true : typeof parsed.data.ok !== "boolean")) {
    return { status: "error", items: [], message: "Resposta inválida da sincronização. Tente novamente." }
  }
  const redact = (value: string) => value.split(token).join("[oculto]")
  const items = parsed.data.items.map(item => ({ ...item, itemId: redact(item.itemId), institution: redact(item.institution), pluggyStatus: redact(item.pluggyStatus), syncStatus: redact(item.syncStatus), message: item.message ? redact(item.message).slice(0, 180) : undefined }))
  const problems = items.filter(item => ["skipped", "failed"].includes(item.syncStatus))
  const details = problems.map(item => `${item.institution}: ${item.message || (item.syncStatus === "skipped" ? "requer sua ação no banco." : "não foi possível atualizar.")}`).join(" ")
  if (httpStatus === 202) return { status: "accepted", items, message: `Atualização em andamento…${details ? ` ${details}` : ""}` }
  const status = problems.length ? (problems.length === items.length ? "error" : "partial") : parsed.data.ok ? "ok" : "error"
  return { status, items, message: details || (status === "ok" ? "Bancos atualizados." : "Não foi possível concluir a atualização. Tente novamente."), finishedAt: parsed.data.finishedAt ? redact(parsed.data.finishedAt) : undefined }
}
