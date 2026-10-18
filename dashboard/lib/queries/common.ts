import type postgres from "postgres"

export type QueryContext = { today: string; consultedAt: string }
export async function getContext(tx: postgres.TransactionSql): Promise<QueryContext> {
  const [row] = await tx<{ today: string; consulted_at: string }[]>`select finance.today_sp()::text today, now()::text consulted_at`
  if (!row) throw new Error("Contexto temporal indisponível")
  return { today: row.today, consultedAt: row.consulted_at }
}

export function reportDatabaseError(error: unknown): string {
  const id = crypto.randomUUID()
  const code = typeof error === "object" && error && "code" in error ? String(error.code) : "unknown"
  console.error("database_error", { id, code })
  return id
}

export async function safeQuery<T>(query: () => Promise<T>): Promise<T | null> {
  try { return await query() } catch (error) { reportDatabaseError(error); return null }
}
