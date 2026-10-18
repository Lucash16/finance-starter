"use client"

type LimitRingProps = {
  label: string
  sublabel?: string
  valueLabel: string
  percent: number
  tone?: "accent" | "warn" | "danger"
}

export function LimitRing({ label, sublabel, valueLabel, percent, tone = "accent" }: LimitRingProps) {
  const clamped = Math.min(100, Math.max(0, percent))
  const r = 42
  const c = 2 * Math.PI * r
  const offset = c - (clamped / 100) * c
  return (
    <div className={`limitRing tone-${tone}`}>
      <svg viewBox="0 0 100 100" role="img" aria-label={`${label}: ${clamped.toFixed(0)}%`}>
        <circle className="limitRingTrack" cx="50" cy="50" r={r} />
        <circle
          className="limitRingFill"
          cx="50"
          cy="50"
          r={r}
          style={{ strokeDasharray: c, strokeDashoffset: offset }}
        />
      </svg>
      <div className="limitRingCenter">
        <strong>{valueLabel}</strong>
        <span>{label}</span>
        {sublabel ? <small>{sublabel}</small> : null}
      </div>
    </div>
  )
}
