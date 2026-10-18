import "server-only"
import { readOnly } from "@/lib/db"
import { decimalToCents } from "@/lib/money"
import { getContext } from "./common"

export async function getInstallments() {
  return readOnly(async tx => {
    const context = await getContext(tx)
    const [totals] = await tx<{total:string;remaining_count:number}[]>`select total::text,remaining_count from finance.dashboard_installment_total`
    const rows = await tx<Record<string, unknown>[]>`select * from finance.dashboard_installments order by account_id,card_last4,estimated_remaining_amount desc`
    return { context, total: decimalToCents(totals!.total), remainingCount: Number(totals!.remaining_count), rows: rows.map(r => ({ ...r, groupRemaining: decimalToCents(r.group_remaining as string), installment: decimalToCents(r.estimated_installment_amount as string), remaining: decimalToCents(r.estimated_remaining_amount as string) })) as Array<Record<string,unknown>&{installment:number;remaining:number;groupRemaining:number}> }
  })
}
