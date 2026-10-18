ALTER TABLE finance.income_entries
 ADD COLUMN IF NOT EXISTS match_pattern text,
 ADD COLUMN IF NOT EXISTS match_window_days smallint NOT NULL DEFAULT 5
  CHECK (match_window_days BETWEEN 0 AND 31);


CREATE OR REPLACE FUNCTION finance.reclassify_pix_no_cartao() RETURNS integer
LANGUAGE plpgsql SET search_path=pg_catalog,finance,extensions AS $$
DECLARE n integer; restored integer;
BEGIN
 WITH RECURSIVE credits AS MATERIALIZED (
  SELECT t.id, t.account_id, t.booking_date, t.signed_amount
  FROM finance.transactions t
  JOIN finance.accounts a ON a.id=t.account_id AND a.type='BANK' AND a.deleted_at IS NULL
  WHERE t.source='pluggy' AND t.deleted_at IS NULL AND t.normalization_status='ready'
   AND t.economic_type_override IS NULL
   AND t.pluggy_type='CREDIT' AND t.signed_amount>0
   AND lower(extensions.unaccent(t.description))~'^credito liberado para pix'
 ), debits AS MATERIALIZED (
  SELECT t.id, t.account_id, t.booking_date, t.signed_amount
  FROM finance.transactions t
  JOIN finance.accounts a ON a.id=t.account_id AND a.type='BANK' AND a.deleted_at IS NULL
  WHERE t.source='pluggy' AND t.deleted_at IS NULL AND t.normalization_status='ready'
   AND t.economic_type_override IS NULL
   AND t.pluggy_type='DEBIT' AND t.signed_amount<0
   AND lower(extensions.unaccent(t.description))~'^pix enviado'
 ), credit_queue AS MATERIALIZED (
  SELECT c.*,row_number() OVER (ORDER BY account_id,signed_amount,booking_date,id) queue_number
  FROM credits c
 ), paired_step(queue_number,used_debit_ids,credit_id,debit_id) AS (
  SELECT 0::bigint,ARRAY[]::uuid[],NULL::uuid,NULL::uuid
  UNION ALL
  SELECT c.queue_number, CASE WHEN chosen.id IS NULL THEN p.used_debit_ids
    ELSE array_append(p.used_debit_ids,chosen.id) END,
   c.id,chosen.id
  FROM paired_step p
  JOIN credit_queue c ON c.queue_number=p.queue_number+1
  LEFT JOIN LATERAL (
   SELECT d.id
   FROM debits d
   WHERE d.account_id=c.account_id AND -d.signed_amount=c.signed_amount
    AND d.booking_date BETWEEN c.booking_date AND c.booking_date+1
    AND NOT d.id=ANY(p.used_debit_ids)
   ORDER BY abs(d.booking_date-c.booking_date),d.booking_date,d.id
   LIMIT 1
  ) chosen ON true
 ), paired AS MATERIALIZED (
  SELECT credit_id,debit_id FROM paired_step WHERE debit_id IS NOT NULL
 ), restored_rows AS (
  UPDATE finance.transactions t
  SET raw=t.raw,
   user_category_id=CASE WHEN t.user_category_id=(SELECT id FROM finance.categories WHERE slug='transferencias-internas')
    THEN NULL ELSE t.user_category_id END
  WHERE t.source='pluggy' AND t.deleted_at IS NULL
   AND t.economic_type_override IS NULL
   AND t.pluggy_type='DEBIT' AND t.classification_reason='pix_no_cartao'
   AND NOT EXISTS (SELECT 1 FROM paired p WHERE p.debit_id=t.id)
  RETURNING 1
 ) SELECT count(*) INTO restored FROM restored_rows;

 WITH RECURSIVE credits AS MATERIALIZED (
  SELECT t.id, t.account_id, t.booking_date, t.signed_amount
  FROM finance.transactions t
  JOIN finance.accounts a ON a.id=t.account_id AND a.type='BANK' AND a.deleted_at IS NULL
  WHERE t.source='pluggy' AND t.deleted_at IS NULL AND t.normalization_status='ready'
   AND t.economic_type_override IS NULL
   AND t.pluggy_type='CREDIT' AND t.signed_amount>0
   AND lower(extensions.unaccent(t.description))~'^credito liberado para pix'
 ), debits AS MATERIALIZED (
  SELECT t.id, t.account_id, t.booking_date, t.signed_amount
  FROM finance.transactions t
  JOIN finance.accounts a ON a.id=t.account_id AND a.type='BANK' AND a.deleted_at IS NULL
  WHERE t.source='pluggy' AND t.deleted_at IS NULL AND t.normalization_status='ready'
   AND t.economic_type_override IS NULL
   AND t.pluggy_type='DEBIT' AND t.signed_amount<0
   AND lower(extensions.unaccent(t.description))~'^pix enviado'
 ), credit_queue AS MATERIALIZED (
  SELECT c.*,row_number() OVER (ORDER BY account_id,signed_amount,booking_date,id) queue_number
  FROM credits c
 ), paired_step(queue_number,used_debit_ids,credit_id,debit_id) AS (
  SELECT 0::bigint,ARRAY[]::uuid[],NULL::uuid,NULL::uuid
  UNION ALL
  SELECT c.queue_number, CASE WHEN chosen.id IS NULL THEN p.used_debit_ids
    ELSE array_append(p.used_debit_ids,chosen.id) END,
   c.id,chosen.id
  FROM paired_step p
  JOIN credit_queue c ON c.queue_number=p.queue_number+1
  LEFT JOIN LATERAL (
   SELECT d.id
   FROM debits d
   WHERE d.account_id=c.account_id AND -d.signed_amount=c.signed_amount
    AND d.booking_date BETWEEN c.booking_date AND c.booking_date+1
    AND NOT d.id=ANY(p.used_debit_ids)
   ORDER BY abs(d.booking_date-c.booking_date),d.booking_date,d.id
   LIMIT 1
  ) chosen ON true
 ), paired AS MATERIALIZED (
  SELECT credit_id,debit_id FROM paired_step WHERE debit_id IS NOT NULL
 ), changed AS (
  UPDATE finance.transactions t
  SET economic_type='internal_transfer', classification_reason='pix_no_cartao',
   user_category_id=(SELECT id FROM finance.categories WHERE slug='transferencias-internas')
  WHERE t.id IN (
   SELECT id FROM credits UNION SELECT debit_id FROM paired
  ) AND t.economic_type_override IS NULL
   AND (t.economic_type, t.classification_reason, t.user_category_id) IS DISTINCT FROM
    ('internal_transfer'::text, 'pix_no_cartao'::text,
     (SELECT id FROM finance.categories WHERE slug='transferencias-internas'))
  RETURNING 1
 ) SELECT count(*) INTO n FROM changed;
 RETURN n+restored;
END $$;



CREATE OR REPLACE FUNCTION finance.reclassify_own_transfer_pairs_after_statement() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,finance AS $$
BEGIN
 IF pg_trigger_depth()=1 THEN
  PERFORM finance.reclassify_own_transfer_pairs();
  PERFORM finance.reclassify_pix_no_cartao();
 END IF;
 RETURN NULL;
END $$;


CREATE OR REPLACE VIEW finance.income_occurrences WITH (security_invoker=true) AS
WITH due AS MATERIALIZED (
 SELECT max(open_due_date) allowance_due_date FROM finance.current_invoice
), months AS MATERIALIZED (
 SELECT (date_trunc('month', finance.today_sp())+((n.n-2)*interval '1 month'))::date month_start
 FROM finance.number_series n WHERE n.n<=20
), plans AS MATERIALIZED (
 SELECT 'plan'::text source, e.id income_id, e.name, e.kind, e.periodicity, e.amount, e.estimated, m.month_start,
  CASE WHEN e.periodicity='once' THEN e.starts_on
   WHEN e.day_of_month IS NOT NULL THEN finance.clamp_month_day(m.month_start, e.day_of_month::int)
  END credit_date,
  e.transaction_id allocation_transaction_id,
  date_trunc('month', link.report_date)::date allocation_month,
  e.match_pattern, e.match_window_days
 FROM finance.income_entries e
 LEFT JOIN finance.transactions_enriched link ON link.id=e.transaction_id
 JOIN months m ON e.active AND (
  (e.periodicity='monthly' AND m.month_start>=date_trunc('month', e.starts_on)::date
   AND (e.ends_on IS NULL OR m.month_start<=date_trunc('month', e.ends_on)::date)
   AND (e.day_of_month IS NULL OR finance.clamp_month_day(m.month_start, e.day_of_month::int)>=e.starts_on)
   AND (e.ends_on IS NULL OR e.day_of_month IS NULL OR finance.clamp_month_day(m.month_start, e.day_of_month::int)<=e.ends_on))
  OR (e.periodicity='yearly' AND extract(month FROM m.month_start)=extract(month FROM e.starts_on)
   AND m.month_start>=date_trunc('month', e.starts_on)::date
   AND (e.ends_on IS NULL OR m.month_start<=e.ends_on))
  OR (e.periodicity='once' AND m.month_start=date_trunc('month', e.starts_on)::date)
 )
), replacement_candidates AS MATERIALIZED (
 SELECT p.income_id, p.month_start, t.id transaction_id,
  row_number() OVER (PARTITION BY t.id ORDER BY abs(t.report_date-p.credit_date), p.credit_date, p.income_id) tx_rank
 FROM plans p
 JOIN finance.transactions_enriched t ON p.match_pattern IS NOT NULL AND p.kind='fixed'
  AND p.periodicity IN ('monthly','yearly') AND p.credit_date IS NOT NULL
  AND t.is_effective AND t.economic_type='income' AND t.signed_amount>0
 AND lower(extensions.unaccent(coalesce(t.description,'')))~p.match_pattern
  AND lower(extensions.unaccent(coalesce(t.description,'')))!~
   '(^|[^a-z])(ferias|13([oº°]| salario)?|decimo terceiro|plr|adiantamento)([^a-z]|$)'
  AND t.report_date BETWEEN p.credit_date-p.match_window_days AND p.credit_date+p.match_window_days
), replacements AS MATERIALIZED (
 SELECT income_id, month_start, transaction_id
 FROM (
  SELECT c.*, row_number() OVER (PARTITION BY c.income_id,c.month_start
   ORDER BY abs(t.report_date-p.credit_date),t.booking_date,t.id) occurrence_rank
  FROM replacement_candidates c
  JOIN plans p USING (income_id,month_start)
  JOIN finance.transactions_enriched t ON t.id=c.transaction_id
  WHERE c.tx_rank=1
 ) ranked WHERE occurrence_rank=1
), plan_rows AS MATERIALIZED (
 SELECT p.source,p.income_id,p.name,p.kind,p.periodicity,p.amount,p.estimated,p.month_start,p.credit_date,
  p.allocation_transaction_id,p.allocation_month,r.transaction_id replaced_by_transaction_id
 FROM plans p LEFT JOIN replacements r USING (income_id,month_start)
), tx AS MATERIALIZED (
 SELECT 'transaction'::text source, e.id income_id, e.description name, 'one_off'::text kind, 'once'::text periodicity,
  e.signed_amount amount, false estimated, date_trunc('month', e.report_date)::date month_start, e.report_date credit_date,
  e.id allocation_transaction_id, date_trunc('month', e.report_date)::date allocation_month,
  NULL::uuid replaced_by_transaction_id
 FROM finance.transactions_enriched e
 WHERE e.is_effective AND e.economic_type='income' AND e.signed_amount>0
  AND NOT EXISTS (SELECT 1 FROM finance.income_entries p WHERE p.active AND p.transaction_id=e.id)
  AND (EXISTS (SELECT 1 FROM replacements r WHERE r.transaction_id=e.id) OR NOT EXISTS (
   SELECT 1 FROM finance.income_entries p
   WHERE p.active AND p.kind='fixed' AND abs(p.amount-e.signed_amount)<=0.01
    AND e.report_date>=date_trunc('month', e.report_date)::date
    AND e.report_date<(date_trunc('month', e.report_date)+interval '1 month')::date
  ))
), rows AS MATERIALIZED (
 SELECT * FROM plan_rows UNION ALL SELECT * FROM tx
), anchored AS MATERIALIZED (
 SELECT r.*, CASE WHEN r.allocation_transaction_id IS NOT NULL AND row_number() OVER (
   PARTITION BY r.allocation_transaction_id
   ORDER BY (r.source='transaction') DESC, (r.month_start=r.allocation_month) DESC NULLS LAST,
    r.month_start, r.income_id)=1
  THEN r.allocation_transaction_id END allocation_target
 FROM rows r
)
SELECT r.source, r.income_id, r.name, r.kind, r.periodicity, r.amount::numeric(14,2) amount, r.month_start, r.credit_date,
 (r.replaced_by_transaction_id IS NULL AND r.month_start=date_trunc('month', finance.today_sp())::date
  AND d.allowance_due_date IS NOT NULL AND (
   (r.credit_date IS NOT NULL AND r.credit_date<=d.allowance_due_date AND r.credit_date>=r.month_start)
   OR (r.credit_date IS NULL AND date_trunc('month', d.allowance_due_date)>r.month_start)
  )) in_vale,
 r.estimated,
 coalesce(al.allocated_amount,0)::numeric(14,2) allocated_amount,
 CASE WHEN r.replaced_by_transaction_id IS NOT NULL THEN 0::numeric(14,2)
  ELSE greatest(r.amount-coalesce(al.allocated_amount,0),0)::numeric(14,2) END available_amount,
 r.replaced_by_transaction_id
FROM anchored r CROSS JOIN due d
LEFT JOIN LATERAL (
 SELECT sum(a.amount) allocated_amount FROM finance.income_allocations a
 WHERE a.transaction_id=r.allocation_target
) al ON true;


REVOKE ALL ON FUNCTION finance.reclassify_pix_no_cartao() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON finance.income_occurrences FROM PUBLIC, anon, authenticated;


DO $income_pix_grants$
DECLARE n text;
BEGIN
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
  GRANT EXECUTE ON FUNCTION finance.reclassify_pix_no_cartao() TO service_role;
  GRANT SELECT ON finance.income_occurrences TO service_role;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN
  GRANT SELECT ON finance.income_occurrences TO finance_reader;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT USAGE ON SCHEMA finance TO supabase_read_only_user;
  GRANT SELECT ON finance.income_occurrences TO supabase_read_only_user;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='dashboard_reader') THEN
  GRANT USAGE ON SCHEMA finance TO dashboard_reader;
  FOR n IN SELECT tablename FROM pg_tables WHERE schemaname='finance' LOOP
   EXECUTE format('GRANT SELECT ON finance.%I TO dashboard_reader',n);
   EXECUTE format('DROP POLICY IF EXISTS dashboard_reader_select ON finance.%I',n);
   EXECUTE format('CREATE POLICY dashboard_reader_select ON finance.%I FOR SELECT TO dashboard_reader USING (true)',n);
  END LOOP;
  FOR n IN SELECT viewname FROM pg_views WHERE schemaname='finance' LOOP
   EXECUTE format('GRANT SELECT ON finance.%I TO dashboard_reader',n);
  END LOOP;
 END IF;
END $income_pix_grants$;
