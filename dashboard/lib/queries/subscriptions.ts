import "server-only"
import { readOnly } from "@/lib/db"
import { decimalToCents } from "@/lib/money"
import { getContext } from "./common"

type SubscriptionRow = {
  id: string
  label: string
  status: string
  expected_amount: string | null
  account_name: string | null
  expected_day: string | null
}

export async function getSubscriptions() {
  return readOnly(async tx => {
    const context = await getContext(tx)
    const [totals] = await tx<{total:string}[]>`select total::text from finance.dashboard_subscription_total`
    const rows = await tx<SubscriptionRow[]>`select id::text,label,status,expected_amount::text,account_name,expected_day::text from finance.dashboard_subscriptions order by label,id`
    return {
      context, total: decimalToCents(totals!.total),
      rows: rows.map(r => ({ ...r, amount: r.expected_amount == null ? null : decimalToCents(r.expected_amount as string) })),
    }
  })
}
