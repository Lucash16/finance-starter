ALTER FUNCTION finance.today_sp() SET search_path = pg_catalog;





DO $reader_function_grants$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN
  GRANT EXECUTE ON FUNCTION finance.today_sp() TO finance_reader;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
  GRANT EXECUTE ON FUNCTION finance.today_sp() TO service_role;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT EXECUTE ON FUNCTION finance.today_sp() TO supabase_read_only_user;
 END IF;
END $reader_function_grants$;


DO $supabase_read_only_grants$
DECLARE n text;
BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  FOREACH n IN ARRAY ARRAY['owner_identities','classification_rules'] LOOP
   EXECUTE format('GRANT SELECT ON finance.%I TO supabase_read_only_user',n);
   EXECUTE format('DROP POLICY IF EXISTS supabase_read_only_select ON finance.%I',n);
   EXECUTE format('CREATE POLICY supabase_read_only_select ON finance.%I FOR SELECT TO supabase_read_only_user USING (true)',n);
  END LOOP;
  GRANT SELECT ON finance.classification_review TO supabase_read_only_user;
 END IF;
END $supabase_read_only_grants$;


CREATE INDEX IF NOT EXISTS budgets_category_idx ON finance.budgets(category_id);

CREATE INDEX IF NOT EXISTS categories_parent_idx ON finance.categories(parent_id);

CREATE INDEX IF NOT EXISTS category_mappings_user_category_idx ON finance.category_mappings(user_category_id);

CREATE INDEX IF NOT EXISTS classification_rules_category_slug_idx ON finance.classification_rules(category_slug);

CREATE INDEX IF NOT EXISTS merchant_aliases_merchant_idx ON finance.merchant_aliases(merchant_id);

CREATE INDEX IF NOT EXISTS pluggy_categories_parent_idx ON finance.pluggy_categories(parent_id);

CREATE INDEX IF NOT EXISTS sync_runs_account_idx ON finance.sync_runs(account_id);

CREATE INDEX IF NOT EXISTS sync_runs_item_idx ON finance.sync_runs(item_id);

CREATE INDEX IF NOT EXISTS transaction_revisions_sync_run_idx ON finance.transaction_revisions(sync_run_id);

CREATE INDEX IF NOT EXISTS transaction_revisions_webhook_event_idx ON finance.transaction_revisions(webhook_event_id);

CREATE INDEX IF NOT EXISTS transactions_bill_account_idx ON finance.transactions(bill_id,account_id);

CREATE INDEX IF NOT EXISTS transactions_card_account_idx ON finance.transactions(card_id,account_id);
