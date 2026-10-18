DO $$ BEGIN CREATE ROLE finance_reader NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; WHEN insufficient_privilege THEN RAISE NOTICE 'finance_reader deve ser criado por administrador'; END $$;

REVOKE ALL ON SCHEMA finance FROM PUBLIC;

REVOKE ALL ON ALL TABLES IN SCHEMA finance FROM PUBLIC,anon,authenticated;

REVOKE ALL ON ALL SEQUENCES IN SCHEMA finance FROM PUBLIC,anon,authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance FROM PUBLIC,anon,authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA finance REVOKE ALL ON TABLES FROM PUBLIC,anon,authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA finance REVOKE ALL ON SEQUENCES FROM PUBLIC,anon,authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA finance REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC,anon,authenticated;

GRANT USAGE ON SCHEMA finance TO service_role,finance_reader;

GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA finance TO service_role;

GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA finance TO service_role;

GRANT EXECUTE ON FUNCTION finance.upsert_accounts(text,jsonb),finance.upsert_bills(text,jsonb),finance.upsert_pluggy_transactions(text,jsonb,uuid),finance.soft_delete_pluggy_transactions(text,text[],text),finance.create_manual_entry(text,jsonb),finance.reconcile_pending(uuid),finance.confirm_reconciliation(uuid),finance.undo_reconciliation(uuid) TO service_role;

GRANT SELECT ON ALL TABLES IN SCHEMA finance TO finance_reader;


DO $$ DECLARE n text; BEGIN
 FOREACH n IN ARRAY ARRAY['items','accounts','cards','credit_card_bills','pluggy_categories','categories','category_mappings','merchants','merchant_aliases','transactions','transaction_revisions','reconciliations','budgets','sync_runs','webhook_events'] LOOP
  EXECUTE format('ALTER TABLE finance.%I ENABLE ROW LEVEL SECURITY',n);
  EXECUTE format('DROP POLICY IF EXISTS finance_reader_select ON finance.%I',n);
  EXECUTE format('CREATE POLICY finance_reader_select ON finance.%I FOR SELECT TO finance_reader USING (true)',n);
  EXECUTE format('DROP POLICY IF EXISTS service_role_all ON finance.%I',n);
  EXECUTE format('CREATE POLICY service_role_all ON finance.%I FOR ALL TO service_role USING (true) WITH CHECK (true)',n);
 END LOOP;
END $$;


DO $block$
DECLARE n text;
BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT USAGE ON SCHEMA finance TO supabase_read_only_user;
  GRANT SELECT ON ALL TABLES IN SCHEMA finance TO supabase_read_only_user;
  FOREACH n IN ARRAY ARRAY['items','accounts','cards','credit_card_bills','pluggy_categories','categories','category_mappings','merchants','merchant_aliases','transactions','transaction_revisions','reconciliations','budgets','sync_runs','webhook_events'] LOOP
   EXECUTE format('DROP POLICY IF EXISTS supabase_read_only_select ON finance.%I',n);
   EXECUTE format('CREATE POLICY supabase_read_only_select ON finance.%I FOR SELECT TO supabase_read_only_user USING (true)',n);
  END LOOP;
 END IF;
END $block$;
