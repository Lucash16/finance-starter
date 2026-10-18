"use client"
import { Area, AreaChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts"
import { formatBRL } from "@/lib/money"
import { formatCivilMonth, formatCivilMonthLong } from "@/lib/dates"

export function MonthlyChart({ data }: { data: { month: string; committed: number }[] }) {
  const compactBRL = (value: number) => value < 100000
    ? `R$ ${Math.round(value / 100).toLocaleString("pt-BR")}`
    : `R$ ${(value / 100000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} mil`
  return <div className="chart" aria-label="Gráfico de evolução mensal"><ResponsiveContainer width="100%" height={260}><AreaChart data={data}><defs><linearGradient id="money" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor="#7b3fe4" stopOpacity={.4}/><stop offset="95%" stopColor="#7b3fe4" stopOpacity={0}/></linearGradient></defs><CartesianGrid strokeDasharray="3 3" stroke="#ebe6f5" vertical={false} /><XAxis dataKey="month" tickFormatter={formatCivilMonth} tick={{ fill: "#8b7aa8", fontSize: 11 }} axisLine={false} tickLine={false} /><YAxis width={72} tick={{ fontSize: 11, fill: "#8b7aa8" }} tickFormatter={v => compactBRL(Number(v))} axisLine={false} tickLine={false} /><Tooltip labelFormatter={v => formatCivilMonthLong(String(v))} formatter={v => formatBRL(Number(v))} /><Area type="monotone" dataKey="committed" stroke="#7b3fe4" strokeWidth={2} fill="url(#money)" /></AreaChart></ResponsiveContainer></div>
}
