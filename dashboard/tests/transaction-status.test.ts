import test from "node:test"
import assert from "node:assert/strict"
import { transactionStatusBadge } from "../lib/transaction-status"

test("pending transactions reflect credit context without changing their status", () => {
  for (const context of [
    { accountType: "CREDIT" },
    { accountName: "Santander Mastercard" },
    { cardLast4: "2222" },
    { category: "Cartão de crédito" },
  ]) {
    assert.deepEqual(transactionStatusBadge({ status: "pending", ...context }), {
      label: "Em processamento", tone: "warn",
    })
  }
  assert.deepEqual(transactionStatusBadge({ status: "pending", accountType: "BANK", cardLast4: null }), {
    label: "Pendente", tone: "warn",
  })
  assert.deepEqual(transactionStatusBadge({ status: "posted", accountType: "CREDIT" }), {
    label: "Autorizado", tone: "good",
  })
  assert.deepEqual(transactionStatusBadge({ status: "unknown" }), {
    label: "unknown", tone: "neutral",
  })
})
