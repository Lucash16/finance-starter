"use client"
import { useId } from "react"
import { Area, AreaChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts"
import { formatBRL } from "@/lib/money"
import { formatCivilDate } from "@/lib/dates"

export function DailySpendingChart({ data }: { data: { day: string; committed: number }[] }) {
  const id = useId().replace(/:/g, "")
  const compact = (value: number) =>
    value < 100000
      ? `R$ ${Math.round(value / 100).toLocaleString("pt-BR")}`
      : `R$ ${(value / 100000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} mil`
  const tickDay = (day: string) => {
    const d = day.split("-")[2] ?? day
    return d
  }
  return (
    <div className="chart" aria-label="Gastos diários no mês">
      <ResponsiveContainer width="100%" height={220}>
        <AreaChart data={data} margin={{ top: 12, right: 8, bottom: 0, left: 0 }}>
          <defs>
            <linearGradient id={`${id}-stroke`} x1="0" y1="0" x2="1" y2="0">
              <stop offset="0%" stopColor="#7b3fe4" stopOpacity={0.9} />
              <stop offset="100%" stopColor="#06b6d4" stopOpacity={0.85} />
            </linearGradient>
            <linearGradient id={`${id}-fill`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stopColor="#7b3fe4" stopOpacity={0.35} />
              <stop offset="95%" stopColor="#7b3fe4" stopOpacity={0} />
            </linearGradient>
          </defs>
          <CartesianGrid strokeDasharray="3 3" stroke="#ebe6f5" vertical={false} />
          <XAxis dataKey="day" tickFormatter={tickDay} tick={{ fill: "#8b7aa8", fontSize: 11 }} axisLine={false} tickLine={false} />
          <YAxis width={56} tick={{ fontSize: 10, fill: "#8b7aa8" }} tickFormatter={v => compact(Number(v))} axisLine={false} tickLine={false} />
          <Tooltip labelFormatter={v => formatCivilDate(String(v))} formatter={v => formatBRL(Number(v))} />
          <Area isAnimationActive={false} type="monotone" dataKey="committed" stroke={`url(#${id}-stroke)`} strokeWidth={3} fill={`url(#${id}-fill)`} dot={false} activeDot={{ r: 5, fill: "#3b82f6", stroke: "#fff", strokeWidth: 2 }} />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  )
}
