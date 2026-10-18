"use client"
import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts"
import { formatBRL } from "@/lib/money"

const COLORS = ["#ef4444", "#ec4899", "#7b3fe4", "#3b82f6", "#06b6d4", "#10b981", "#f59e0b", "#8b5cf6"]

export function CategoryChart({
  data,
}: {
  data: { name: string; committed: number; totalCommitted?: number; budget?: number | null }[]
}) {
  const total = data[0]?.totalCommitted ?? 0
  const slices = data.map((d, i) => ({
    ...d,
    pct: total > 0 ? Math.round((d.committed / total) * 100) : 0,
    fill: COLORS[i % COLORS.length],
  }))

  return (
    <div className="categoryBlock">
      <div className="donutWrap" aria-label="Gastos por categoria">
        <ResponsiveContainer width="100%" height={220}>
          <PieChart>
            <Pie
              isAnimationActive={false}
              cornerRadius={7}
              data={slices}
              dataKey="committed"
              nameKey="name"
              cx="50%"
              cy="50%"
              innerRadius="62%"
              outerRadius="88%"
              paddingAngle={4}
              strokeWidth={0}
            >
              {slices.map(entry => (
                <Cell key={entry.name} fill={entry.fill} />
              ))}
            </Pie>
            <Tooltip formatter={v => formatBRL(Number(v))} />
          </PieChart>
        </ResponsiveContainer>
        <div className="donutCenter">
          <strong>{formatBRL(total)}</strong>
          <span>no mês</span>
        </div>
      </div>
      <ul className="categoryRows">
        {slices.map(row => {
          const cap = row.budget && row.budget > 0 ? row.budget : null
          const usedPct = cap ? Math.min(100, (row.committed / cap) * 100) : row.pct
          return (
            <li key={row.name}>
              <div className="categoryRowHead">
                <span className="categoryPct">{row.pct}%</span>
                <strong>{row.name}</strong>
              </div>
              <div className="categoryBar" role="presentation">
                <i style={{ width: `${usedPct}%`, background: row.fill }} />
              </div>
              <p className="categoryRowMeta">
                {cap
                  ? `Gasto ${formatBRL(row.committed)} de ${formatBRL(cap)}`
                  : `${formatBRL(row.committed)} no mês`}
              </p>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
