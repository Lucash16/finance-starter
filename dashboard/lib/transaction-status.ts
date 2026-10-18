type TransactionStatusContext = {
  status: string
  accountType?: string | null
  accountName?: string | null
  cardLast4?: string | null
  category?: string | null
}

export function transactionStatusBadge(transaction: TransactionStatusContext): {
  label: string
  tone: "warn" | "good" | "neutral"
} {
  if (transaction.status === "posted") return { label: "Autorizado", tone: "good" }
  if (transaction.status === "pending") {
    const credit = transaction.cardLast4 != null ||
      /credit|crédito|card|cartão/i.test([
        transaction.accountType, transaction.accountName, transaction.category,
      ].join(" "))
    return { label: credit ? "Em processamento" : "Pendente", tone: "warn" }
  }
  return { label: transaction.status, tone: "neutral" }
}
