import Link from "next/link"

export const maxDuration = 180
import { BillAccountCard, isBillWarning } from "@/components/dashboard/bill-account-card"
import { TransactionAvatar } from "@/components/dashboard/transaction-avatar"
import { CategoryChart } from "@/components/charts/category-chart"
import { DailySpendingChart } from "@/components/charts/daily-spending-chart"
import { MonthlyChart } from "@/components/charts/monthly-chart"
import { MonthlySpendingChart } from "@/components/charts/monthly-spending-chart"
import { Badge, DatabaseError, EmptyState, UpdatedAt } from "@/components/ui"
import { formatBRL } from "@/lib/money"
import { transactionStatusBadge } from "@/lib/transaction-status"
import { cardDisplayName, displayName } from "@/lib/display-name"
import { formatCivilDate, formatCivilMonthLong } from "@/lib/dates"
import {
  groupRecentCycles,
  selectCycles,
  type CycleCardRow,
  type CycleRow,
} from "@/lib/bills"
import { requireOwner } from "@/lib/require-owner"
import { getOverview } from "@/lib/queries/overview"
import { getInstallments } from "@/lib/queries/installments"
import { reportDatabaseError, safeQuery } from "@/lib/queries/common"

type Overview = Awaited<ReturnType<typeof getOverview>>

export default async function OverviewPage({
  searchParams,
}: {
  searchParams: Promise<{ meses?: string; fatura?: string }>
}) {
  await requireOwner()
  const params = await searchParams
  const months = params.meses === "6" ? 6 : 12

  let data: Overview | null = null
  try {
    data = await getOverview(months)
  } catch (error) {
    reportDatabaseError(error)
  }
  if (!data) return <main className="dashMain"><DatabaseError /></main>

  const installments = await safeQuery(() => getInstallments())
  const today = data.context.today
  const cashflow = data.cashflow

  const cycles = groupRecentCycles(
    data.cycles as unknown as CycleRow[],
    data.cycleCards as unknown as CycleCardRow[],
  )
  const selected = selectCycles(cycles, params.fatura)
  const accounts = [...new Set(cycles.map(c => c.accountId))]

  const topInstallments = (installments?.rows ?? []).slice(0, 6)
  const monthLabel = formatCivilMonthLong(`${today.slice(0, 7)}-01`)
  const dailyTotal = data.monthCommitted
  const dailyTxCount = data.monthTxCount
  const pending = data.pendingHighlight
  const pendingBadge = pending ? transactionStatusBadge(pending) : null


  return (
    <main className="dashMain">
      <section className="mobileHero dashEnter">
        <div className="mobileHeroTop">
          <div className="mobileHeroUser">
            <span className="mobileHeroAvatar" aria-hidden>F</span>
            <div>
              <h1>Meu orçamento</h1>
              <UpdatedAt value={data.context.consultedAt} />
            </div>
          </div>
          <div className="mobileHeroActions">
            <span className="monthPill" title="Mês de referência">{monthLabel}</span>
          </div>
        </div>
        <p className="mobileHeroLabel">Disponível para gastar (vale)</p>
        <p className="mobileHeroValue">{formatBRL(cashflow.vale)}</p>
        <p className="mobileHeroSub">Fluxo de caixa · {formatCivilDate(cashflow.asOf)}</p>
      </section>

      <section className="hScrollCards dashEnter" style={{ animationDelay: "40ms" }} aria-label="Resumo rápido">
        <article className="summaryCard">
          <span>Projeção</span>
          <strong>{formatBRL(cashflow.projected)}</strong>
        </article>
        <article className="summaryCard">
          <span>Fatura atual</span>
          <strong>{formatBRL(cashflow.invoice)}</strong>
          <small>{formatBRL(cashflow.processing)} em processamento</small>
        </article>
        <article className="summaryCard accent">
          <span>Diário</span>
          <strong>{formatBRL(cashflow.daily)}</strong>
          <small>{cashflow.remainingDays} dia{cashflow.remainingDays === 1 ? "" : "s"} restantes</small>
        </article>
      </section>

      <section className="surfaceCard budgetOverview dashEnter">
        <h2 className="sectionTitleSm">Fluxo de caixa</h2>
        <div className="budgetCols">
          <div><span>Recorrentes restantes</span><strong>{formatBRL(cashflow.recurring)}</strong></div>
          <div><span>Receitas até o vencimento</span><strong>{formatBRL(cashflow.incomes)}</strong></div>
          <div><span>Meta de economia</span><strong>{formatBRL(cashflow.savings)}</strong></div>
        </div>
      </section>

      {pending && (
        <section className="pendingCard surfaceCard dashEnter" style={{ animationDelay: "60ms" }}>
          <div className="pendingCardBody">
            <TransactionAvatar label={pending.merchantName} category={pending.category} />
            <div>
              <strong>{displayName(pending.merchantName)}</strong>
              <span>{pending.category} · {cardDisplayName(pending.accountName, pending.cardLast4)}</span>
              <span className="pendingAmount">{pending.signed === null ? "—" : formatBRL(Math.abs(pending.signed))}</span>
            </div>
          </div>
          {pendingBadge && (
            <div className="pendingStatus">
              <Badge tone={pendingBadge.tone}>{pendingBadge.label}</Badge>
            </div>
          )}
        </section>
      )}

      <section className="surfaceCard budgetOverview dashEnter" style={{ animationDelay: "80ms" }}>
        <h2 className="sectionTitleSm">Visão do envelope</h2>
        <div className="budgetCols">
          <div>
            <span>Entradas</span>
            <strong>{formatBRL(cashflow.incomes)}</strong>
          </div>
          <div>
            <span>Comprometido</span>
            <strong>{formatBRL(cashflow.committed)}</strong>
          </div>
          <div>
            <span>Pode gastar</span>
            <strong className={cashflow.vale < 0 ? "negative" : undefined}>{formatBRL(cashflow.vale)}</strong>
          </div>
        </div>
        <div className="progressBar budgetBar" role="progressbar" aria-label="Projeção sobre entradas após a meta de economia" aria-valuemin={0} aria-valuemax={100} aria-valuenow={cashflow.envelopeProgress * 100}>
          <i style={{ width: `${cashflow.envelopeProgress * 100}%` }} />
        </div>
        <p className="muted">Comprometido inclui projeção e meta de economia.</p>
      </section>

      <section className="surfaceCard dashEnter" style={{ animationDelay: "100ms" }}>
        <div className="sectionHead">
          <div>
            <h2>Gastos diários</h2>
            <p className="muted">Tendência no mês · {formatCivilDate(today)}</p>
          </div>
        </div>
        <p className="chartSummary">
          <strong>{formatBRL(dailyTotal)}</strong> em {dailyTxCount} lançamento{dailyTxCount === 1 ? "" : "s"} no mês
        </p>
        {data.dailySpend.length ? (
          <DailySpendingChart data={data.dailySpend} />
        ) : (
          <EmptyState>Sem gastos diários neste mês.</EmptyState>
        )}
      </section>

      <section className="surfaceCard dashEnter">
        <div className="sectionHead">
          <div>
            <h2>Gastos mensais</h2>
            <p className="muted">Últimos 6 meses · confirmados e pendentes</p>
          </div>
        </div>
        <MonthlySpendingChart currentMonth={today} data={data.monthly.slice(-6).map(m => ({ month: m.month, committed: m.committed }))} />
      </section>

      <section className="dashSection dashEnter" style={{ animationDelay: "120ms" }}>
        <div className="sectionHead">
          <h2>Últimas transações</h2>
          <Link className="textLink" href="/transacoes">Ver todas</Link>
        </div>
        {data.recentTransactions.length ? (
          <ul className="txList">
            {data.recentTransactions.map(tx => (
              <li key={tx.id}>
                <TransactionAvatar label={tx.merchantName} category={tx.category} />
                <div className="txListBody">
                  <strong>{displayName(tx.merchantName)}</strong>
                  <span>{tx.category}</span>
                </div>
                <div className="txListAmount">
                  <b className={tx.signed !== null && tx.signed < 0 ? "negative" : undefined}>
                    {tx.signed === null ? "—" : formatBRL(tx.signed)}
                  </b>
                  <small>{formatCivilDate(tx.reportDate)}</small>
                </div>
              </li>
            ))}
          </ul>
        ) : (
          <div className="surfaceCard"><EmptyState>Nenhuma transação recente.</EmptyState></div>
        )}
      </section>

      <section className="dashSection dashEnter" style={{ animationDelay: "140ms" }}>
        <div className="sectionHead">
          <h2>Faturas</h2>
          <span className="sectionHint">Últimos ciclos</span>
        </div>
        {accounts.length ? (
          <div className="stack">
            {accounts.map(accountId => {
              const options = cycles.filter(c => c.accountId === accountId)
              const bill = selected.get(accountId)!
              const warnings = options.filter(isBillWarning)
              return (
                <BillAccountCard
                  key={accountId}
                  accountName={bill.accountName}
                  options={options}
                  bill={bill}
                  months={months}
                  warnings={warnings.filter(w => w.key !== bill.key)}
                />
              )
            })}
          </div>
        ) : (
          <div className="surfaceCard"><EmptyState>Nenhuma fatura disponível.</EmptyState></div>
        )}
      </section>

      {data.creditLimits.length > 0 && (
        <section className="dashSection dashEnter" style={{ animationDelay: "160ms" }}>
          <div className="sectionHead"><h2>Limites</h2><span className="sectionHint">Pluggy</span></div>
          <div className="limitGrid">
            {data.creditLimits.map(acc => {
              const pct = acc.total > 0 && acc.used !== null ? Math.min(100, Math.max(0, acc.used / acc.total * 100)) : 0
              return <article className="surfaceCard creditLimitCard" key={acc.id}>
                <h3>{cardDisplayName(acc.name)}</h3>
                <p>Utilizado <strong>{acc.used === null ? "Não informado" : formatBRL(acc.used)}</strong></p>
                <div className="progressBar" role="progressbar" aria-label={`Limite utilizado de ${cardDisplayName(acc.name)}`} aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}><i style={{ width: `${pct}%` }} /></div>
                <p>Disponível <strong>{acc.available === null ? "Não informado" : formatBRL(acc.available)}</strong></p>
                <small>Limite total {formatBRL(acc.total)}</small>
              </article>
            })}
          </div>
        </section>
      )}

      <section className="dashSection dashEnter" style={{ animationDelay: "180ms" }}>
        <div className="sectionHead">
          <h2>Parcelas próximas</h2>
          <Link className="textLink" href="/parcelas">Ver todas</Link>
        </div>
        {topInstallments.length ? (
          <ul className="rowList">
            {topInstallments.map((r, i) => (
              <li key={`${r.account_id}-${r.card_last4}-${i}`}>
                <TransactionAvatar label={String(r.merchant_name)} category="parcelas" />
                <div>
                  <strong>{displayName(String(r.merchant_name))}</strong>
                  <span>
                    {cardDisplayName(String(r.account_name), r.card_last4 ? String(r.card_last4) : null)} · {String(r.remaining_installments)} restantes
                  </span>
                </div>
                <div className="rowListAmount">
                  <b>{formatBRL(r.installment)}</b>
                  <small>/mês</small>
                </div>
              </li>
            ))}
          </ul>
        ) : (
          <div className="surfaceCard"><EmptyState>Nenhuma parcela futura.</EmptyState></div>
        )}
      </section>

      <section className="dashSection dashEnter" style={{ animationDelay: "200ms" }}>
        <div className="sectionHead">
          <h2>Categorias</h2>
          <span className="sectionHint">Mês atual</span>
        </div>
        {data.categories.length ? (
          <div className="surfaceCard chartCard">
            <CategoryChart
              data={data.categories.slice(0, 8).map(c => ({
                name: c.name,
                committed: c.committed, totalCommitted: c.totalCommitted,
              }))}
            />
          </div>
        ) : (
          <div className="surfaceCard"><EmptyState>Sem gastos neste mês.</EmptyState></div>
        )}
      </section>

      <section className="surfaceCard dashEnter chartCard" style={{ animationDelay: "220ms" }}>
        <div className="sectionHead">
          <div>
            <h2>Evolução mensal</h2>
            <p className="muted">Comprometimento</p>
          </div>
          <div className="segmented">
            <Link className={months === 6 ? "segActive" : undefined} href="/?meses=6">6m</Link>
            <Link className={months === 12 ? "segActive" : undefined} href="/?meses=12">12m</Link>
          </div>
        </div>
        <MonthlyChart data={data.monthly.map(m => ({ month: m.month, committed: m.committed }))} />
      </section>
    </main>
  )
}
