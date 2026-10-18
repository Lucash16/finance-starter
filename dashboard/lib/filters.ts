import { z } from "zod"

const civilDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine(value => {
  const date = new Date(`${value}T00:00:00Z`)
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value
}, "Data inválida")
const queryBoolean = z.enum(["0", "1"]).transform(value => value === "1")
const positiveInteger = z.string().regex(/^\d+$/).transform(Number).pipe(z.number().int().positive())
const origin = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(?::\d{4})?$/i)

export const transactionFiltersSchema = z.object({
  periodo: z.enum(["atual", "anterior", "personalizado"]).default("atual"), de: civilDate.optional(), ate: civilDate.optional(),
  origem: origin.optional(), categoria: z.uuid().optional(), q: z.string().trim().max(120).optional().transform(v => v || undefined),
  status: z.enum(["todos", "posted", "pending"]).default("todos"), naoGastos: queryBoolean.default(false),
  excluidas: queryBoolean.default(false), pagina: positiveInteger.pipe(z.number().max(1000)).default(1),
  tamanho: positiveInteger.pipe(z.number().max(100)).default(25),
}).superRefine((value, ctx) => {
  if (value.periodo === "personalizado" && (!value.de || !value.ate)) ctx.addIssue({ code: "custom", message: "Informe as duas datas" })
  if (value.de && value.ate) {
    const days = (Date.parse(value.ate) - Date.parse(value.de)) / 86400000
    if (days < 0 || days > 366) ctx.addIssue({ code: "custom", message: "O período deve ter até 366 dias" })
  }
})

export type TransactionFilters = z.infer<typeof transactionFiltersSchema> & { accountId?: string; cardLast4?: string }

export function parseTransactionFilters(raw: Record<string, string | string[] | undefined>): TransactionFilters {
  for (const key of Object.keys(raw)) if (Array.isArray(raw[key])) throw new Error(`Parâmetro repetido: ${key}`)
  const parsed = transactionFiltersSchema.parse(raw)
  if (parsed.de && parsed.ate) parsed.periodo = "personalizado"
  const [accountId, cardLast4] = parsed.origem?.split(":") ?? []
  return { ...parsed, naoGastos: parsed.naoGastos || parsed.excluidas, accountId, cardLast4 }
}

export function escapeLike(value: string): string { return value.replace(/[\\%_]/g, "\\$&") }
