import { formatInstant } from "@/lib/dates"
export function EmptyState({ children }: { children: React.ReactNode }) { return <p className="empty">{children}</p> }
export function UpdatedAt({ value }: { value: string }) { return <p className="updated">Consultado em {formatInstant(value)}</p> }
export function DatabaseError() { return <section className="panel error"><h2>Não foi possível carregar os dados</h2><p>O banco pode estar pausado — tente de novo em instantes.</p></section> }
export function Badge({ children, tone = "neutral" }: { children: React.ReactNode; tone?: "good" | "warn" | "bad" | "neutral" }) { return <span className={`badge ${tone}`}>{children}</span> }
