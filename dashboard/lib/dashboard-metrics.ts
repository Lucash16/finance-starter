import { decimalToCents } from "./money"

/** Convert view values to cents and expose server-side envelope display helpers. */
export function cashflowMetrics(row: Record<string, unknown>) {
  const money = (key: string) => {
    const value = row[key]
    if (typeof value !== "string" && typeof value !== "number") throw new Error(`Fluxo de caixa inválido: ${key}`)
    return decimalToCents(value)
  }
  const remainingDays = Number(row.remaining_days)
  if (row.remaining_days == null || !Number.isInteger(remainingDays) || remainingDays < 0) throw new Error("Dias restantes inválidos")
  const projected = money("projected_amount")
  const incomes = money("incomes_before_due")
  const savings = money("savings_goal")
  return {
    asOf: String(row.as_of),
    vale: money("vale_amount"),
    daily: money("daily_quota"),
    projected,
    invoice: money("invoice_current"),
    processing: money("processing_amount"),
    recurring: money("recurring_remaining"),
    incomes,
    savings,
    committed: money("committed_amount"),
    envelopeProgress: Number(row.envelope_progress),
    remainingDays,
  }
}
