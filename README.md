# Personal Finance Starter

A self-hosted personal finance starter built with Supabase/Postgres, Supabase Edge Functions, and a Next.js dashboard. Connect financial institutions through Pluggy or MeuPluggy, record manual entries, and use agent skills to query your finances.

The Postgres `finance` schema owns reconciliation, classification, balances, budgets, and projections. The dashboard reads financial values from database views on the server; the frontend handles presentation only. Google OAuth restricts access to the configured owner.

## Architecture

```text
Pluggy / MeuPluggy ──> pluggy-sync Edge Function ──┐
Manual entries ──────> manual-entry Edge Function ┤
                                                v
                                    Supabase / Postgres
                                      finance schema
                                  reconciliation + views
                                      |             |
                             server queries     read-only MCP
                                      |             |
                               Next.js dashboard  Agent skills
                                      |
                               Google OAuth owner
```

Internal transfers, credit card bill payments, and investments are excluded from spending. Register owner identities to recognize transfers between your own accounts. Meal vouchers and other external benefits stay outside the budget. See [AGENTS.md](AGENTS.md) for data and agent rules.

## Repository layout

| Path | Purpose |
| --- | --- |
| `db/migrations/` | Schema, reconciliation functions, views, triggers, and permissions; no personal seed data. |
| `supabase/functions/` | Pluggy sync, manual entries, shared code, and function tests. |
| `dashboard/` | Next.js application, Google OAuth access, server queries, tests, and dependency lockfile. |
| `dashboard/sql/` | Read-only database login setup for the dashboard. |
| `skills/` | Reusable agent workflows for financial queries and synchronization. |
| `scripts/` | Sync helper and secret scanner. |
| `tests/` | Local starter contract and scanner checks. |
| `.env.example` | Environment variable names with empty values. |
| [SETUP.md](SETUP.md) | Detailed installation and operation instructions. |

## Quick start

Prerequisites: a Node version compatible with `dashboard/package.json`, npm, Bash, Python 3, Deno, psql, and the Supabase CLI for Edge Function deployment.

1. **Create a Supabase project.** Copy `.env.example` into a private, Git-ignored environment file and configure your own credentials. Keep the `finance` schema private; it does not need PostgREST exposure.
2. **Apply migrations.** Run `db/migrations/*.sql` in filename order against a new database, stopping at the first error. This is the canonical migration directory; the Supabase CLI does not read it automatically. After the first deployment, use new migrations for schema or formula changes.
3. **Connect Pluggy or MeuPluggy.** Configure application credentials and consent, register connections privately, and configure your own banks, payment sources, owner identities, categories, income, budgets, and savings goals. Follow the setup guide's import and account-linking sequence.
4. **Deploy the Edge Functions.** Set private secrets, deploy `pluggy-sync` and `manual-entry`, and configure authenticated webhooks. Schedule regular backfill and webhook queue draining with `scripts/sync-now.sh`. MeuPluggy sync imports available data; it does not guarantee a fresh institution update.
5. **Configure dashboard access.** Create the read-only login using `dashboard/sql/dashboard_reader.sql`, set `DATABASE_URL` to that login, configure Google OAuth and the owner's verified account allowlist, and set the private authentication and sync variables.
6. **Start the dashboard.** With its private environment configured, run:

   ```bash
   cd dashboard
   npm ci
   npm run dev
   ```

   For Vercel deployment, use `dashboard` as the root directory and configure the OAuth callback for your domain.
7. **Enable optional workflows.** Install directories from `skills/` in your agent client and configure a read-only MCP connection. Follow the setup guide to create an authenticated manual-entry shortcut.

See [SETUP.md](SETUP.md) for exact commands, environment variables, webhook configuration, scheduling, and operational checks.

### Empty by default

The starter ships with empty personal records. Financial views may remain empty or incomplete until your own connections and configuration are in place. `/preview` uses fictional demo data. Other dashboard pages require authentication and a configured database, with no mock fallback.

## Security

- `.env.example` contains empty values only. Never commit environment files, credentials, tokens, private identifiers, or financial data.
- Keep database credentials and financial queries on the server. Use a read-only database role for dashboard queries and agent access; do not give query agents administrative credentials.
- Configure independent secrets for synchronization, webhooks, and manual entries. Keep authenticated shortcuts and service responses private.
- Run `scripts/scan-secrets.sh` before sharing or pushing changes. Configure a private denylist as described in [SETUP.md](SETUP.md); the default scan uses generic patterns. The scanner flags private environment files without reading their contents.
- Agents must not change records without explicit instruction or access the network or database to validate code without authorization. Use local tests with mocks.

## Validation

After installing dependencies in your environment:

```bash
scripts/scan-secrets.sh
(cd dashboard && npm test && npm run typecheck && npm run lint)
PLUGGY_ITEM_IDS=fixture-2411,fixture-2537 deno test --cached-only --allow-env supabase/functions/tests/pagination.test.ts supabase/functions/tests/webhook.test.ts supabase/functions/tests/config.test.ts supabase/functions/tests/manual-entry.test.ts
python3 tests/starter_contract.py
python3 tests/scan_secrets_test.py
```

The fixture values in the Deno command are synthetic test inputs. `--cached-only` requires dependencies already in the Deno cache and prevents network access. Integration tests are separate: run them only with explicit authorization against a disposable database, never production. Validate migrations, access controls, synchronization, reconciliation, and projections in your own environment before relying on the results.

The lockfile preserves exact dependency versions. Two integrity hashes matching prohibited patterns were omitted, and one package URL uses an equivalent hyphen escape. Validate npm installation in your own connected environment.

## License

Licensed under the [MIT License](LICENSE).
