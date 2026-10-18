import assert from "node:assert/strict"
import { test } from "node:test"
import { parseRefreshResponse } from "../lib/manual-refresh"

const item = { itemId: "one", institution: "Banco", pluggyStatus: "UPDATED", syncStatus: "done" }
test("manual refresh handles success, MFA, partial and accepted responses", () => {
  const body = { ok: true, mode: "update", items: [item], finishedAt: "2026-10-14T12:00:00Z" }
  assert.equal(parseRefreshResponse(body, 200, "test-token").status, "ok")
  const mfa = { ...item, syncStatus: "skipped", message: "Confirme o acesso no banco." }
  assert.equal(parseRefreshResponse({ ...body, items: [item, mfa] }, 200, "test-token").status, "partial")
  const failed = parseRefreshResponse({ ...body, items: [mfa] }, 200, "test-token")
  assert.equal(failed.status, "error")
  assert.match(failed.message, /Confirme o acesso/)
  assert.equal(parseRefreshResponse({ mode: "update", accepted: true, items: [item] }, 202, "test-token").status, "accepted")
})
test("manual refresh rejects malformed responses and redacts credentials", () => {
  assert.equal(parseRefreshResponse({ items: [] }, 200, "test-token").status, "error")
  assert.equal(parseRefreshResponse({ mode: "update", items: [item] }, 202, "test-token").status, "error")
  const result = parseRefreshResponse({ ok: false, mode: "update", items: [{ ...item, institution: "test-token", syncStatus: "failed", message: "test-token" }] }, 200, "test-token")
  assert.equal(JSON.stringify(result).includes("test-token"), false)
})
