# Instalação de finanças pessoais

Este starter começa com cadastros vazios. Configure apenas dados do novo titular em ambiente privado. Requisitos: Node compatível com `dashboard/package.json`, npm, Bash, Python 3, Deno e psql. Supabase CLI é obrigatória para o caminho de deploy das funções documentado abaixo. Os comandos abaixo são instruções para instalação; não foram executados contra serviços externos.

## 1. Criar o Supabase

Crie um projeto no painel Supabase, escolha região e guarde a senha do banco em um gerenciador. Use `YOUR_PROJECT_REF` ao preencher URLs. O schema `finance` não precisa ser exposto no PostgREST. Copie `.env.example` para um arquivo privado ignorado pelo Git e preencha as variáveis necessárias.

- `SUPABASE_DB_URL`: conexão Postgres da função, com usuário administrador dedicado ou credencial do projeto; use pooler em modo transação e conexão TLS.
- `DATABASE_URL`: conexão Postgres do dashboard com papel somente leitura, nunca a credencial administrativa.
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`: identificadores/chaves do projeto para ferramentas Supabase. O dashboard atual usa Postgres direto e não depende dessas três variáveis.
- Não use prefixo `NEXT_PUBLIC_` para credenciais. Não publique arquivos de ambiente.

## 2. Aplicar migrations

`db/migrations` contém DDL, views, funções, triggers e permissões, sem cadastros pessoais. Aplique em ordem de nome, em um projeto novo, com psql:

```bash
export PGSSLMODE=require
for migration in db/migrations/*.sql; do
  psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 --single-transaction -f "$migration" || break
done
```

Pare ao primeiro erro e revise antes de continuar. A pasta canônica é `db/migrations`; `supabase db push` não lê essa pasta automaticamente. Para adotar o controle de migrations da CLI, copie os arquivos para `supabase/migrations` em seu ambiente de implantação e mantenha uma única fonte canônica. Depois do primeiro deploy, mudanças entram em migrations novas. Não reaplique o conjunto inteiro sobre banco com dados.

## 3. Conectar Pluggy / MeuPluggy

1. No dashboard de desenvolvedores Pluggy, crie uma aplicação e guarde `PLUGGY_CLIENT_ID` e `PLUGGY_CLIENT_SECRET` em arquivo privado.
2. No MeuPluggy, conecte as instituições com consentimento do titular e autorize o compartilhamento das conexões com essa aplicação. Confirme que está usando a mesma aplicação/ambiente ao consultar os items.
3. Consulte os items da aplicação no dashboard Pluggy e copie o campo `id` de cada conexão. Pela API, autentique com `POST https://api.pluggy.ai/auth`, enviando JSON com `clientId` e `clientSecret`; use o `apiKey` retornado no cabeçalho `X-API-KEY` de `GET https://api.pluggy.ai/items`. Leia os IDs em `results[].id` e siga a paginação, se houver. Execute isso privadamente, sem publicar respostas, logs ou tokens. Se a lista estiver vazia, revise o consentimento e a aplicação antes de continuar.
4. Coloque os IDs separados por vírgula em `PLUGGY_ITEM_IDS` no arquivo privado `edge.env`; o comando `supabase secrets set` da próxima seção publica essa configuração como secret. Cadastre os mesmos IDs em `finance.items` conforme abaixo. Nada deve ficar fixo no código.

**MeuPluggy:** items não podem ser atualizados à força via `PATCH /items`: a API retorna 400. A atualização acontece aproximadamente a cada 24 horas ou quando o usuário toca **Atualizar** no app MeuPluggy. Webhooks `item/updated` e `transactions/*` funcionam. O botão do dashboard tenta atualizar conectores elegíveis e, para MeuPluggy, sincroniza os dados já disponíveis; isso não significa que o banco foi consultado novamente.

Antes do primeiro sync, cadastre os items no SQL Editor privado, usando dados reais da nova conexão:

```sql
INSERT INTO finance.items(pluggy_id,institution_name,institution_slug)
VALUES ('YOUR_ITEM_ID','YOUR_INSTITUTION_NAME','YOUR_INSTITUTION_SLUG')
ON CONFLICT(pluggy_id) DO UPDATE SET institution_name=excluded.institution_name,
 institution_slug=excluded.institution_slug;
```

Os slugs devem ser consistentes com os cadastros de bancos e fontes de pagamento. Cadastre seus próprios `banks`, `payment_sources` (conta, cartão pai, finais e ciclos), `owner_identities` (nome/documento normalizados para reconhecer transferências), categorias/mapeamentos, `income_entries`, `savings_goals`, `budgets` e `recurring_overrides`. Consulte as definições nas migrations para campos obrigatórios. Nada disso vem preenchido; sem fontes/renda/metas, as projeções podem estar vazias ou incompletas. Não cadastre VR ou outros benefícios externos no orçamento. Agrupe cartões físicos/virtuais na mesma fonte pai para evitar duplicação. Compare a primeira projeção com o aplicativo bancário.

Exemplo de configuração privada: substitua todos os `YOUR_*` antes de executar no SQL Editor. Neste schema, a renda recorrente fica em `finance.income_entries` (não existe tabela `finance.recurring_incomes`). `YOUR_MONTHLY_SAVINGS_AMOUNT` é o aporte mensal planejado. Use valores decimais sem separadores de milhar e datas ISO.

```sql
INSERT INTO finance.banks (name, slug)
VALUES ('YOUR_BANK_NAME', 'YOUR_BANK_SLUG');

INSERT INTO finance.payment_sources (bank_id, slug, kind, name, account_id, link_origin)
SELECT id, 'YOUR_CHECKING_SOURCE_SLUG', 'checking', 'YOUR_CHECKING_SOURCE_NAME',
       'YOUR_ACCOUNT_UUID'::uuid, 'manual'
FROM finance.banks WHERE slug = 'YOUR_BANK_SLUG';

INSERT INTO finance.income_entries (name, kind, amount, day_of_month, periodicity, starts_on)
VALUES ('YOUR_INCOME_NAME', 'fixed', 'YOUR_MONTHLY_AMOUNT'::numeric,
        'YOUR_PAYMENT_DAY'::smallint, 'monthly', 'YOUR_START_DATE'::date);

INSERT INTO finance.savings_goals (name, amount, starts_on)
VALUES ('YOUR_GOAL_NAME', 'YOUR_MONTHLY_SAVINGS_AMOUNT'::numeric, 'YOUR_START_DATE'::date);
```

`YOUR_ACCOUNT_UUID` é o ID interno em `finance.accounts`, disponível depois da primeira importação, não o ID Pluggy. Execute o exemplo uma vez; ajuste cadastros existentes em vez de repetir inserts. Fontes de cartão usam `kind='credit'` e os campos de ciclo definidos nas migrations.

## 4. Publicar as Edge Functions

Dentro deste diretório:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase secrets set --env-file /CAMINHO/PRIVADO/edge.env
supabase functions deploy pluggy-sync
supabase functions deploy manual-entry
```

O arquivo privado `edge.env` deve conter `SUPABASE_DB_URL`, `PLUGGY_CLIENT_ID`, `PLUGGY_CLIENT_SECRET`, `PLUGGY_ITEM_IDS`, `PLUGGY_WEBHOOK_SECRET`, `FINANCE_SYNC_TOKEN` e `MANUAL_ENTRY_TOKEN`. `FINANCE_HISTORY_START` é opcional, no formato AAAA-MM-DD; sem ele, sync completo importa cerca de um ano. Secrets são lidos exclusivamente do ambiente, sem fallback no Vault. Gere tokens longos e independentes em um gerenciador. As funções usam autenticação própria: `verify_jwt=false` está no config.

Configure `FINANCE_SYNC_URL` como `https://YOUR_PROJECT_REF.supabase.co/functions/v1/pluggy-sync`. Registre na aplicação Pluggy o webhook desse endpoint, com cabeçalho `X-Webhook-Secret` igual ao segredo privado configurado. Inscreva `item/updated`, `transactions/created`, `transactions/updated`, `transactions/deleted`; o payload precisa de `eventId` e `event`. Sem o cabeçalho, o endpoint rejeita a chamada.

O backfill/full importa dados por GET; o modo update pode tentar PATCH em conectores elegíveis. Retorno 202 é aceitação, não conclusão. Eventos `item/updated` ficam na fila e precisam do drain.

## 5. Cron e sincronização

Com ambiente carregado, execute `scripts/sync-now.sh` para atualizar agora. Configure um agendador externo com as mesmas variáveis privadas:

```bash
FINANCE_SYNC_MODE=backfill scripts/sync-now.sh
FINANCE_SYNC_MODE=drain scripts/sync-now.sh
```

Exemplo executável de cron com curl: crie `/CAMINHO/PRIVADO/finance-sync.sh`, substitua `YOUR_PROJECT_REF` e carregue `FINANCE_SYNC_TOKEN` de um arquivo privado de shell (permissão 600). Não use `set -x`. O token é enviado pelo stdin do curl para evitar incluí-lo nos argumentos do processo.

```bash
#!/usr/bin/env bash
set -euo pipefail
source /CAMINHO/PRIVADO/cron.env
[[ -n "${FINANCE_SYNC_TOKEN-}" ]] || { printf 'Configure o token no arquivo privado.\n' >&2; exit 1; }
mode="${1:-drain}"
printf 'Authorization: Bearer %s\n' "$FINANCE_SYNC_TOKEN" |
  curl --fail --silent --show-error --output /dev/null \
    --request POST --header @- \
    "https://YOUR_PROJECT_REF.supabase.co/functions/v1/pluggy-sync?mode=$mode"
```

Execute `chmod 700 /CAMINHO/PRIVADO/finance-sync.sh` e acrescente com `crontab -e`:

```cron
*/5 * * * * /CAMINHO/PRIVADO/finance-sync.sh drain
0 6 * * * /CAMINHO/PRIVADO/finance-sync.sh backfill
```

Agende backfill diariamente e drain a cada poucos minutos. `FINANCE_SYNC_MODE=full` serve para importação inicial; respeite histórico/consentimento disponíveis. Veja `finance.sync_health`, `finance.pluggy_sync_status`, `finance.sync_runs` e `finance.webhook_events` para distinguir aceitação, execução e falha. Um projeto pausado não executa cron.

Alternativa: habilite `pg_cron`, `pg_net` e Vault no Supabase; guarde URL e token no Vault privado e agende chamadas `net.http_post` para `?mode=backfill` e `?mode=drain`, com Authorization Bearer obtida de `vault.decrypted_secrets`. Use nomes de jobs distintos, confirme resultado em `cron.job_run_details` e monitore HTTP. Não coloque tokens literais nas migrations nem no texto de jobs. O uso do Vault aqui é exclusivo do cron, não das Edge Functions.

## 6. Dashboard na Vercel e Google OAuth

Crie o papel de login somente leitura usando `dashboard/sql/dashboard_reader.sql` no SQL Editor, substituindo `YOUR_DB_PASSWORD` privadamente. Ele herda `finance_reader`, usa RLS e transações somente leitura. Configure a URL desse papel em `DATABASE_URL`.

No Google Cloud, configure a tela de consentimento e um cliente OAuth Web. Cadastre a origem HTTPS do domínio e redirect `https://YOUR_DOMAIN/api/auth/callback/google`. Para desenvolvimento, cadastre `http://localhost:3000/api/auth/callback/google`. Em modo de teste do Google, adicione `YOUR_EMAIL` como usuário de teste.

Na Vercel importe o repositório e escolha **Root Directory: dashboard**. Use o lockfile e `npm ci`. Configure `AUTH_GOOGLE_ID`, `AUTH_GOOGLE_SECRET`, `AUTH_SECRET`, `AUTH_URL` (URL pública), `AUTH_TRUST_HOST=true`, `ALLOWED_EMAILS` (e-mails verificados separados por vírgula), `DATABASE_URL`, `FINANCE_SYNC_URL` e `FINANCE_SYNC_TOKEN`. Deploys de preview precisam de domínio/redirect autorizado se forem testar login.

Localmente, crie `dashboard/.env.local` privado com essas variáveis e execute:

```bash
cd dashboard
npm ci
npm run dev
```

Acesse `/preview` para exemplos genéricos. As demais páginas exigem login e banco configurados; não há fallback para mocks.

## 7. MCP do Supabase para agentes

No cliente MCP do seu agente, configure o servidor Supabase oficial para o projeto novo, com URL `https://mcp.supabase.com/mcp?project_ref=YOUR_PROJECT_REF&read_only=true`, e conclua a autenticação pelo cliente. Guarde a configuração fora deste starter. Não compartilhe tokens de acesso.

Sugestão: quando usar um servidor MCP Postgres, forneça um login que herde `finance_reader`, com `default_transaction_read_only=on`, sem permissões de escrita ou execução de funções mutantes. No MCP hospedado do Supabase, `read_only=true` é uma restrição do servidor, não uma garantia de conexão como esse papel Postgres. Confira o projeto e as ferramentas autorizadas; não forneça service role ao agente de consulta. Consulte views com SELECT e revise `AGENTS.md`.

## 8. Atalho no iPhone para lançamentos manuais

No app Atalhos, crie perguntas para descrição, valor positivo e tipo (`expense` ou `income`). Gere um identificador único para `request_id` uma vez por lançamento; preserve-o em uma repetição da mesma requisição. Reusar ID com payload diferente retorna 409.

Use **Obter Conteúdo de URL**, método POST, em `https://YOUR_PROJECT_REF.supabase.co/functions/v1/manual-entry`. Cabeçalhos: `Content-Type: application/json` e `Authorization: Bearer YOUR_MANUAL_ENTRY_TOKEN`, preenchidos privadamente. Corpo JSON:

```json
{
  "request_id": "YOUR_UNIQUE_REQUEST_ID",
  "payload": {
    "kind": "expense",
    "amount": "YOUR_AMOUNT",
    "description": "YOUR_DESCRIPTION",
    "date": "YOUR_DATE"
  }
}
```

Use valor numérico positivo ou string no formato brasileiro e data AAAA-MM-DD. Opcionais: `account` (ID Pluggy/alias cadastrado), `card_last4` e `category` (categoria existente). Sem conta, o lançamento fica sem vínculo para reconciliação posterior. A função retorna ID, estado da reconciliação e saldo do envelope; não insira esses dados manualmente no painel. Não compartilhe o atalho com token embutido. Após o sync, confira se a conciliação evita contar a mesma compra duas vezes.

## 9. Instalar skills

Copie cada diretório de `skills/` para o diretório de skills do seu cliente, por exemplo `$CODEX_HOME/skills/`, ou importe cada SKILL.md pelo cliente. Abra uma nova sessão para carregar. Informe ao agente a localização deste starter e qual conexão MCP foi configurada. As skills consultam views; não dependem de scripts particulares da pessoa de origem.

## 10. Validar e operar

Antes do primeiro push, copie `scripts/scan-denylist.example.txt` para `scripts/scan-denylist.local.txt` e acrescente seus nomes pessoais, e-mails, project_ref e outros identificadores privados como expressões regulares (uma por linha). O arquivo local é ignorado pelo Git; nunca o adicione à força. A alternativa é apontar `SCAN_DENYLIST_FILE` para um arquivo privado externo. Sem arquivo local, a varredura usa apenas os padrões genéricos do exemplo.

Execute `scripts/scan-secrets.sh` antes de compartilhar. Depois de adotar Git, ele examina arquivos rastreados e arquivos novos não ignorados, incluindo o próprio script; antes disso, examina os arquivos de trabalho, exceto dependências, artefatos e diretórios privados de ferramentas. A denylist privada não é alvo da varredura. Arquivos `.env` privados são sinalizados sem ler seu conteúdo. Não adicione `.env` ao Git. Instale gitleaks para complementar a verificação.

No dashboard, rode `npm test`, `npm run typecheck` e `npm run lint`. Para as funções, use os comandos de testes offline em README. Testes de integração são opcionais e precisam de um banco descartável privado; nunca aponte `FINANCE_TEST_DB` para produção. Migrations deste starter não foram aplicadas contra banco nesta preparação: valide-as primeiro em seu projeto novo e confira RLS, login não autorizado, sync, conciliação e projeções antes de usar para decisões.
