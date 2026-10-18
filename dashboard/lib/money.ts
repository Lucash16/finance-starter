export function decimalToCents(value: string | number | null): number {
  if (value === null) return 0
  const normalized = String(value)
  if (!/^-?\d+(\.\d+)?$/.test(normalized)) throw new Error("Decimal monetário inválido")
  const negative = normalized.startsWith("-")
  const [whole = "0", fraction = ""] = normalized.replace("-", "").split(".")
  const cents = Number(whole) * 100 + Number((fraction + "00").slice(0, 2))
  if (!Number.isSafeInteger(cents)) throw new Error("Valor monetário fora da faixa segura")
  return negative ? -cents : cents
}

export function formatBRL(cents: number): string {
  return new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(cents / 100)
}
