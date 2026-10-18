"use client"
export default function ErrorPage({ reset }: { reset: () => void }) { return <main><section className="panel error"><h1>Não foi possível carregar os dados</h1><p>O banco pode estar pausado — tente de novo em instantes.</p><button className="primary" onClick={reset}>Tentar novamente</button></section></main> }
