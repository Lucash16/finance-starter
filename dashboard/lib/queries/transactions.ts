import "server-only"
import { readOnly } from "@/lib/db"
import { decimalToCents } from "@/lib/money"
import { escapeLike, type TransactionFilters } from "@/lib/filters"
import { getContext } from "./common"

export async function getTransactionPage(filters: TransactionFilters) {
  return readOnly(async tx => {
    const context = await getContext(tx)
    const range: { from: string; to: string } = filters.periodo === "personalizado"
      ? { from: filters.de!, to: filters.ate! }
      : await (async()=>{const r=(await tx<{ from_date: string; to_date: string }[]>`select case when ${filters.periodo}='anterior' then (date_trunc('month',finance.today_sp())-interval '1 month')::date else date_trunc('month',finance.today_sp())::date end::text from_date, case when ${filters.periodo}='anterior' then (date_trunc('month',finance.today_sp())-interval '1 day')::date else (date_trunc('month',finance.today_sp())+interval '1 month'-interval '1 day')::date end::text to_date`)[0]!;return {from:r.from_date,to:r.to_date}})()
    const pattern = filters.q ? `%${escapeLike(filters.q)}%` : null
    const predicate = tx`e.report_date>=${range.from}::date and e.report_date<=${range.to}::date
      and (${filters.accountId ?? null}::uuid is null or e.account_id=${filters.accountId ?? null}::uuid)
      and (${filters.cardLast4 ?? null}::text is null or e.card_last4=${filters.cardLast4 ?? null})
      and (${filters.categoria ?? null}::uuid is null or e.effective_category_id=${filters.categoria ?? null}::uuid)
      and (${filters.status}='todos' or e.status=${filters.status})
      and (${filters.naoGastos} or e.counts_as_expense) and (${filters.excluidas} or e.is_effective)
      and (${pattern}::text is null or e.description ilike ${pattern} escape E'\\\\' or e.merchant_name ilike ${pattern} escape E'\\\\' or e.merchant_normalized ilike ${pattern} escape E'\\\\')`
    const rows = await tx<Record<string, unknown>[]>`select e.id::text,e.report_date::text,e.description,e.merchant_name,e.effective_category,e.account_name,e.account_type,e.card_last4,e.installment_number,e.total_installments,e.signed_amount::text,e.currency,e.status,e.economic_type,e.is_effective,e.counts_as_expense,e.exclusion_reason,e.deletion_reason,e.normalization_status from finance.transactions_enriched e where ${predicate} order by e.report_date desc,e.id desc limit ${filters.tamanho} offset ${(filters.pagina-1)*filters.tamanho}`
    const [totals] = await tx<Record<string, unknown>[]>`select count(*)::int row_count,coalesce(sum(e.posted_expense_amount),0)::text posted,coalesce(sum(e.pending_commitment_amount),0)::text pending from finance.transactions_enriched e where ${predicate}`
    const origins = await tx<Record<string, unknown>[]>`select distinct account_id::text,account_name,account_type,institution_name,card_last4 from finance.transactions_enriched where account_id is not null order by institution_name,account_name,card_last4`
    const categories = await tx<Record<string, unknown>[]>`select distinct effective_category_id::text,effective_category from finance.transactions_enriched where effective_category_id is not null order by effective_category`
    return { context, range, rows: rows.map(r => ({ ...r, signed: r.signed_amount === null ? null : decimalToCents(r.signed_amount as string) })) as Array<Record<string,unknown>&{signed:number|null}>, totals: { count: Number(totals?.row_count ?? 0), posted: decimalToCents(totals?.posted as string ?? "0"), pending: decimalToCents(totals?.pending as string ?? "0") }, origins, categories }
  })
}
