"use client"

import { Bar, BarChart, CartesianGrid, Cell, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts"
import { formatBRL } from "@/lib/money"
import { formatCivilMonth, formatCivilMonthLong } from "@/lib/dates"

export function MonthlySpendingChart({ data, currentMonth }: {
  data: { month: string; committed: number }[]
  currentMonth: string
}) {
  return (
    <div className="chart" aria-label="Gastos mensais nos últimos seis meses">
      <ResponsiveContainer width="100%" height={220}>
        <BarChart data={data} margin={{ top: 12, right: 8, bottom: 0, left: 0 }} accessibilityLayer>
          <CartesianGrid strokeDasharray="3 3" stroke="#ebe6f5" vertical={false} />
          <XAxis dataKey="month" tickFormatter={formatCivilMonth} interval={0} tick={{ fill: "#8b7aa8", fontSize: 11 }} axisLine={false} tickLine={false} />
          <YAxis width={56} tick={{ fill: "#8b7aa8", fontSize: 10 }} tickFormatter={v => `R$ ${(Number(v) / 100000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} mil`} axisLine={false} tickLine={false} />
          <Tooltip labelFormatter={v => formatCivilMonthLong(String(v))} formatter={v => [formatBRL(Number(v)), "Gastos"]} cursor={{ fill: "#f2edf9" }} />
          <Bar dataKey="committed" radius={[6, 6, 0, 0]} maxBarSize={36} isAnimationActive={false}>
            {data.map(row => <Cell key={row.month} fill={row.month.slice(0, 7) === currentMonth.slice(0, 7) ? "#7b3fe4" : "#d4c6eb"} />)}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}
