-- Execute manualmente no SQL Editor do Supabase, substituindo o placeholder.
-- NÃO use uma senha real neste repositório.
DO $$ BEGIN
  CREATE ROLE dashboard_reader LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD 'YOUR_DB_PASSWORD';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE dashboard_reader PASSWORD 'YOUR_DB_PASSWORD';
END $$;
GRANT finance_reader TO dashboard_reader;
ALTER ROLE dashboard_reader SET default_transaction_read_only = on;
ALTER ROLE dashboard_reader SET statement_timeout = '5s';
ALTER ROLE dashboard_reader SET lock_timeout = '1s';
ALTER ROLE dashboard_reader SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE dashboard_reader SET search_path = finance, public;

-- Permissão para a data de referência das views.
GRANT EXECUTE ON FUNCTION finance.today_sp() TO finance_reader;

-- Verificação (execute conectado como dashboard_reader):
-- SELECT count(*) FROM finance.transactions_enriched; -- deve funcionar
-- SELECT count(*) FROM finance.current_bills;          -- deve funcionar
-- INSERT INTO finance.budgets(name,start_date,end_date_exclusive,amount) VALUES ('x',current_date,current_date+1,1); -- deve falhar
-- SELECT finance.upsert_accounts('x','[]'::jsonb);      -- deve falhar
