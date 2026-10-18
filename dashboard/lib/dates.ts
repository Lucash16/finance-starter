export function formatCivilDate(value: string | null): string {
  if (!value) return "Não informada"
  const [year, month, day] = value.split("-")
  return `${day}/${month}/${year}`
}

export function formatInstant(value: string | Date | null): string {
  if (!value) return "Nunca"
  return new Intl.DateTimeFormat("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" }).format(new Date(value))
}

const shortMonths = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
const longMonths = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"]
export function formatCivilMonth(value: string): string {
  const [year = 0, month = 1] = value.split("-").map(Number)
  return `${shortMonths[month - 1]}/${String(year).slice(-2)}`
}
export function formatCivilMonthLong(value: string): string {
  const [year = 0, month = 1] = value.split("-").map(Number)
  return `${longMonths[month - 1]} de ${year}`
}
