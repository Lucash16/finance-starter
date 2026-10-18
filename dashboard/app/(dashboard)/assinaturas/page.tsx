import { DatabaseError, EmptyState, UpdatedAt, Badge } from "@/components/ui"
import { formatBRL } from "@/lib/money"
import { accountDisplayName, displayName } from "@/lib/display-name"
import { requireOwner } from "@/lib/require-owner"
import { getSubscriptions } from "@/lib/queries/subscriptions"
import { safeQuery } from "@/lib/queries/common"

const statuses: Record<string, string> = {
  active: "Ativa", ending: "Encerrando", cancel_requested: "Cancelamento solicitado",
}

export default async function SubscriptionsPage() {
  await requireOwner()
  const data = await safeQuery(getSubscriptions)
  if (!data) return <main><DatabaseError /></main>
  const total = data.total
  const missingAmounts = data.rows.some(row => row.amount === null)
  return <main>
    <header className="pageHeader"><div><p className="eyebrow">RECORRÊNCIAS</p><h1>Assinaturas</h1><p className="muted">Recorrências cadastradas e vigentes. Estimativa mensal pelos valores esperados.</p></div><UpdatedAt value={data.context.consultedAt} /></header>
    <section className="heroCard compact"><p className="eyebrow">CUSTO MENSAL ESTIMADO</p><strong>{formatBRL(total)}</strong><p>{data.rows.length} recorrência(s) vigente(s)</p>{missingAmounts && <p>Estimativa parcial: há valores não informados.</p>}</section>
    <section className="panel cards">{data.rows.length ? data.rows.map(row => <article className="bill subscription" key={String(row.id)}>
      <div className="subscriptionText"><b title={String(row.label)}>{displayName(String(row.label))}</b><p title={String(row.account_name ?? "Conta não informada")}>{accountDisplayName(row.account_name)}</p><small>Próximo dia esperado: {row.expected_day ? `dia ${row.expected_day}` : "não informado"}</small></div>
      <div className="amount"><strong>{row.amount === null ? "Valor não informado" : `${formatBRL(row.amount)}/mês`}</strong><Badge tone={row.status === "active" ? "good" : "warn"}>{statuses[String(row.status)] ?? String(row.status)}</Badge></div>
    </article>) : <EmptyState>Nenhuma assinatura vigente.</EmptyState>}</section>
  </main>
}
