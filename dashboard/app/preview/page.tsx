// Static design fixture: all monetary values on /preview are illustrative mocks.
import { IconCalendar, IconHome, IconList, IconRepeat, IconSync } from "@/components/icons"
import { CategoryChart } from "@/components/charts/category-chart"
import { DailySpendingChart } from "@/components/charts/daily-spending-chart"
import { MonthlySpendingChart } from "@/components/charts/monthly-spending-chart"
import { TransactionAvatar } from "@/components/dashboard/transaction-avatar"

const mockDaily = [
  { day: "2026-10-01", committed: 42000 },
  { day: "2026-10-05", committed: 89000 },
  { day: "2026-10-08", committed: 125000 },
  { day: "2026-10-12", committed: 178000 },
  { day: "2026-10-14", committed: 210000 },
]

const mockCategories = [
  { name: "Mercado", committed: 50000, totalCommitted: 120000 },
  { name: "Transporte", committed: 20000, totalCommitted: 120000 },
  { name: "Moradia", committed: 30000, totalCommitted: 120000 },
  { name: "Pessoal", committed: 20000, totalCommitted: 120000 },
]

const mockMonthly = [
  { month: "2026-05-01", committed: 285000 },
  { month: "2026-06-01", committed: 324000 },
  { month: "2026-07-01", committed: 268000 },
  { month: "2026-08-01", committed: 356000 },
  { month: "2026-09-01", committed: 301000 },
  { month: "2026-10-01", committed: 210000 },
]

const mockTx = [
  { id: "1", name: "Hortifruti", cat: "Mercado", amount: "-R$ 10,00" },
  { id: "2", name: "Transferência", cat: "Conta", amount: "R$ 700,00" },
  { id: "3", name: "Lanche", cat: "Mercado", amount: "-R$ 5,45" },
]

export default function PreviewPage() {
  return (
    <div className="appShell previewShell">
      <div className="content">
        <main className="dashMain" style={{ maxWidth: 390 }}>
          <section className="mobileHero dashEnter">
            <div className="mobileHeroTop">
              <div className="mobileHeroUser">
                <span className="mobileHeroAvatar">F</span>
                <div>
                  <h1>Meu orçamento</h1>
                  <p className="updated">Prévia estática</p>
                </div>
              </div>
              <span className="monthPill">outubro de 2026</span>
            </div>
            <p className="mobileHeroLabel">Disponível para gastar (vale)</p>
            <p className="mobileHeroValue">R$ 450,00</p>
            <p className="mobileHeroSub">R$ 1.400,00 comprometido · envelope principal</p>
          </section>

          <section className="hScrollCards" aria-label="Resumo ilustrativo">
            <article className="summaryCard"><span>Projeção</span><strong>R$ 3.200,00</strong><small className="trendUp">-3,4% vs mês ant.</small></article>
            <article className="summaryCard"><span>Comprometido</span><strong>R$ 1.400,00</strong><small>R$ 120,00 pendente</small></article>
            <article className="summaryCard accent"><span>Diário</span><strong>R$ 32,14</strong><small>14 dias restantes</small></article>
          </section>

          <section className="surfaceCard budgetOverview">
            <h2 className="sectionTitleSm">Visão do envelope</h2>
            <div className="budgetCols">
              <div><span>Entradas</span><strong>R$ 4.650,00</strong></div>
              <div><span>Comprometido</span><strong>R$ 4.200,00</strong></div>
              <div><span>Pode gastar</span><strong>R$ 450,00</strong></div>
            </div>
            <div className="progressBar budgetBar"><i style={{ width: "87.67%" }} /></div>
            <p className="muted">Comprometido inclui projeção e meta de economia.</p>
          </section>

          <section className="surfaceCard">
            <h2>Gastos diários</h2>
            <p className="chartSummary"><strong>R$ 2.100,00</strong> em 31 lançamentos no mês</p>
            <DailySpendingChart data={mockDaily} />
          </section>

          <section className="surfaceCard">
            <h2>Gastos mensais</h2>
            <p className="muted">Últimos 6 meses · confirmados e pendentes</p>
            <MonthlySpendingChart data={mockMonthly} currentMonth="2026-10-14" />
          </section>

          <section className="dashSection">
            <div className="sectionHead"><h2>Últimas transações</h2></div>
            <ul className="txList">
              {mockTx.map(tx => (
                <li key={tx.id}>
                  <TransactionAvatar label={tx.name} category={tx.cat} />
                  <div className="txListBody"><strong>{tx.name}</strong><span>{tx.cat}</span></div>
                  <div className="txListAmount"><b>{tx.amount}</b></div>
                </li>
              ))}
            </ul>
          </section>

          <section className="surfaceCard chartCard">
            <h2>Categorias</h2>
            <CategoryChart data={mockCategories} />
          </section>
        </main>
      </div>
      <nav className="bottomNav" aria-hidden>
        <span className="navLink active"><IconHome className="navIcon" />Início</span>
        <span className="navLink"><IconList className="navIcon" />Transações</span>
        <button type="button" className="navFab" aria-label="Atualizar bancos (prévia estática)" disabled><IconSync /></button>
        <span className="navLink"><IconCalendar className="navIcon" />Parcelas</span>
        <span className="navLink"><IconRepeat className="navIcon" />Assinaturas</span>
      </nav>
    </div>
  )
}
