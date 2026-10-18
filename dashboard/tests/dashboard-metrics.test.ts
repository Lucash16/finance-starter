import test from "node:test"
import assert from "node:assert/strict"
import { cashflowMetrics } from "../lib/dashboard-metrics"
const row = { as_of: "2026-01-01", vale_amount: "100", projected_amount: "200", invoice_current: "120", processing_amount: "30", recurring_remaining: "50", incomes_before_due: "400", savings_goal: "100", daily_quota: "10", remaining_days: 10, committed_amount: "300", envelope_progress: 0.5 }
test("reads amounts and presentation ratio directly from database fields", () => {
 assert.equal(cashflowMetrics(row).committed,30000)
 assert.equal(cashflowMetrics(row).envelopeProgress,0.5)
 assert.equal(cashflowMetrics({...row, projected_amount:"900"}).committed,30000)
 assert.equal(cashflowMetrics({...row, vale_amount:"-10"}).vale,-1000)
})
test("missing values fail instead of inventing a balance", () => {
 assert.throws(()=>cashflowMetrics({...row,vale_amount:null}))
 assert.throws(()=>cashflowMetrics({...row,remaining_days:null}))
})
