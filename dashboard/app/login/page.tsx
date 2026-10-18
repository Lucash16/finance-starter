import { login } from "./actions"

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams
  return <main className="login"><section className="loginCard"><div className="logo">F</div><p className="eyebrow">ESPAÇO PESSOAL</p><h1>Suas finanças,<br/>sem ruído.</h1><p className="muted">Acesso reservado ao proprietário.</p>{error && <p className="notice">Não foi possível autorizar este acesso.</p>}<form action={login}><button className="primary" type="submit">Entrar com Google</button></form><small>Somente leitura · Dados privados</small></section></main>
}
