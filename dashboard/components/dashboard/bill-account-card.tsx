import Link from "next/link"
import { Badge } from "@/components/ui"
import { formatCivilDate } from "@/lib/dates"
import { formatBRL } from "@/lib/money"
import { badgeTone, isUnpaid, paymentLabels, type BillGroup } from "@/lib/bills"

type BillAccountCardProps = {
  accountName: string
  options: BillGroup[]
  bill: BillGroup
  months: number
  warnings: BillGroup[]
}

function billQuery(months: number, key: string) {
  const q = new URLSearchParams({ meses: String(months), fatura: key })
  return `/?${q}`
}

export function BillAccountCard({ accountName, options, bill, months, warnings }: BillAccountCardProps) {
  const total = bill.official ?? bill.computed
  const differs = bill.official !== null && bill.official !== bill.computed

  return (
    <article className="billCard dashEnter">
      <header className="billCardHead">
        <div>
          <h3>{accountName}</h3>
          {warnings.map(w => (
            <p className="inlineNotice" key={w.key}>
              A pagar {formatCivilDate(w.dueDate)} · {formatBRL(w.remaining)} · {paymentLabels[w.paymentStatus]}
            </p>
          ))}
        </div>
      </header>

      <div className="chipRow" role="tablist" aria-label={`Faturas de ${accountName}`}>
        {options.map(o => {
          const active = o.key === bill.key
          return (
            <Link
              key={o.key}
              href={billQuery(months, o.key)}
              className={`chip${active ? " chipActive" : ""}`}
              role="tab"
              aria-selected={active}
              scroll={false}
            >
              {o.isCurrent ? "Atual" : formatCivilDate(o.closingDate)}
              <span className={`chipDot tone-${badgeTone(o.paymentStatus) ?? "neutral"}`} />
            </Link>
          )
        })}
      </div>

      <div className="billCardBody">
        <div className="billCardMeta">
          <Badge tone={badgeTone(bill.paymentStatus)}>{paymentLabels[bill.paymentStatus]}</Badge>
          <p>
            {bill.isCurrent
              ? "Fatura aberta · vencimento a definir"
              : `Fechada ${formatCivilDate(bill.closingDate)} · vence ${formatCivilDate(bill.dueDate)}`}
          </p>
          {bill.cards.map(card => (
            <small key={card.last4}>Final {card.last4}: {formatBRL(card.subtotal)}</small>
          ))}
          {!bill.cards.some(c => c.subtotal !== 0) && <small>Sem compras sincronizadas</small>}
          {bill.usedLimit !== null && bill.isCurrent && (
            <small>Limite utilizado (Pluggy): {formatBRL(bill.usedLimit)}</small>
          )}
          {differs && (
            <small className="inlineNotice">Total oficial ≠ calculado ({formatBRL(bill.computed)}).</small>
          )}
        </div>
        <div className="billCardAmount">
          <strong>{formatBRL(total)}</strong>
          <span>Pago {formatBRL(bill.paid)}</span>
          <span>Restante {formatBRL(bill.remaining)}</span>
          {bill.paymentStatus === "paid" && (
            <span>
              {bill.paidAt
                ? `Paga em ${formatCivilDate(bill.paidAt)}`
                : bill.paymentSource === "no_amount_due"
                  ? "Sem valor a pagar"
                  : "Paga · data não informada"}
            </span>
          )}
        </div>
      </div>
    </article>
  )
}

export function isBillWarning(c: BillGroup) {
  return isUnpaid(c.paymentStatus)
}
