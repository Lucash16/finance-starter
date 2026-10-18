export function displayName(value: string): string {
  if (value !== value.toLocaleLowerCase("pt-BR")) return value
  return value.replace(/(^|[\s/\-])([\p{L}])/gu, (_, prefix: string, letter: string) =>
    prefix + letter.toLocaleUpperCase("pt-BR"))
}

export function cardDisplayName(name: string, last4?: string | null): string {
  const bank = /santander/i.test(name) ? "Santander" : /nubank/i.test(name) ? "Nubank" : displayName(name)
  return last4 ? `${bank} • ${last4}` : bank
}

const institutions: Array<[RegExp, string]> = [
  [/\b(nu pagamentos|nubank|nu financeira)\b/i, "Nubank"],
  [/\bsantander\b/i, "Santander"],
  [/\bita[uú](?=\s|$|[^\p{L}\p{N}])/iu, "Itaú"],
  [/\bbradesco\b/i, "Bradesco"],
  [/\bbanco do brasil\b/i, "Banco do Brasil"],
  [/\bcaixa econ[oô]mica\b/i, "Caixa"],
  [/\bbanco inter\b/i, "Inter"],
]

export function accountDisplayName(value: string | null | undefined): string {
  const name = value?.trim().replace(/\s+/g, " ") || "Conta não informada"
  const known = institutions.find(([pattern]) => pattern.test(name))
  if (known) return known[1]
  const label = displayName(name)
  return label.length > 32 ? `${label.slice(0, 31).trimEnd()}…` : label
}
