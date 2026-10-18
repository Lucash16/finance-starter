DROP VIEW IF EXISTS finance.cashflow_month;

DROP VIEW IF EXISTS finance.income_occurrences;

DROP VIEW IF EXISTS finance.current_invoice;

DROP VIEW IF EXISTS finance.installment_schedule;

DROP VIEW IF EXISTS finance.expenses;

DROP VIEW IF EXISTS finance.recurring_charges;

DROP VIEW IF EXISTS finance.pluggy_sync_status;

DROP VIEW IF EXISTS finance.payment_source_review;


CREATE TABLE IF NOT EXISTS finance.number_series (
 n integer PRIMARY KEY CHECK (n BETWEEN 1 AND 60)
);

ALTER TABLE finance.number_series ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_all ON finance.number_series;

CREATE POLICY service_role_all ON finance.number_series FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS finance_reader_select ON finance.number_series;

CREATE POLICY finance_reader_select ON finance.number_series FOR SELECT TO finance_reader USING (true);

REVOKE ALL ON finance.number_series FROM PUBLIC, anon, authenticated;


CREATE VIEW finance.expenses WITH (security_invoker=true) AS
SELECT e.id, src.payment_source_id, e.account_id, e.card_last4,
 CASE WHEN e.deleted_at IS NULL THEN e.expense_amount ELSE -e.signed_amount END::numeric(14,2) amount,
 e.purchase_date, e.booking_date, e.description, e.effective_category category,
 CASE
  WHEN e.deleted_at IS NOT NULL THEN 'cancelado'
  WHEN e.status='pending' AND e.account_type='CREDIT' THEN 'em_processamento'
  WHEN e.status='pending' THEN 'pendente'
  ELSE 'lancado' END status,
 CASE WHEN e.source='pluggy' THEN 'pluggy' ELSE 'manual' END origin,
 e.source, e.pluggy_id
FROM finance.transactions_enriched e
LEFT JOIN LATERAL (
 SELECT ps.id payment_source_id
 FROM finance.payment_sources ps
 WHERE ps.active AND ps.account_id=e.account_id
  AND (ps.card_last4 IS NOT DISTINCT FROM e.card_last4 OR (ps.card_last4 IS NULL AND ps.parent_id IS NULL AND ps.kind=CASE WHEN e.account_type='CREDIT' THEN 'credit' ELSE 'checking' END))
 ORDER BY (ps.card_last4 IS NOT DISTINCT FROM e.card_last4 AND ps.card_last4 IS NOT NULL) DESC, (ps.parent_id IS NOT NULL) DESC
 LIMIT 1
) src ON true
WHERE e.economic_type IN ('expense','refund')
 AND (e.deleted_at IS NOT NULL OR e.counts_as_expense OR e.expense_amount<>0);


CREATE VIEW finance.installment_schedule WITH (security_invoker=true) AS
WITH observed AS MATERIALIZED (
 SELECT e.id transaction_id, e.account_id, coalesce(e.card_last4,'') card_last4, e.card_id,
  e.description, e.merchant_name, e.merchant_normalized, e.installment_number, e.total_installments,
  e.installment_total_amount, abs(e.signed_amount)::numeric(14,2) parcel_amount, e.booking_date, e.purchase_date, e.status,
  e.bill_id, e.bill_post_date,
  coalesce(e.purchase_date, (e.booking_date-((e.installment_number-1)*interval '1 month'))::date) purchase_anchor,
  regexp_replace(coalesce(e.description,''), '\s*\(?\d{1,2}\s*/\s*\d{1,2}\)?\s*$', '') description_key
 FROM finance.transactions_enriched e
 WHERE e.is_effective AND e.account_type='CREDIT' AND e.economic_type='expense'
  AND coalesce(e.total_installments,1)>1 AND e.installment_number IS NOT NULL
  AND e.installment_number<=e.total_installments AND e.signed_amount IS NOT NULL
), grouped AS MATERIALIZED (
 SELECT account_id, card_last4, max(card_id::text)::uuid card_id, purchase_anchor, total_installments, description_key,
  max(merchant_normalized) merchant_normalized, max(merchant_name) merchant_name, max(description) description,
  max(installment_total_amount) purchase_total,
  (array_agg(parcel_amount ORDER BY installment_number, transaction_id))[1] standard_amount,
  count(*)::int installments_posted, max(installment_number) last_observed_installment
 FROM observed
 GROUP BY account_id, card_last4, purchase_anchor, total_installments, description_key, merchant_normalized
), series AS MATERIALIZED (
 SELECT g.*, n.n installment_number,
  (g.purchase_anchor+((n.n-1)*interval '1 month'))::date posting_date,
  CASE WHEN g.purchase_total IS NOT NULL AND n.n=g.total_installments
   THEN (g.purchase_total-g.standard_amount*(g.total_installments-1))::numeric(14,2)
   ELSE g.standard_amount END installment_amount,
  md5(concat_ws('|', g.account_id::text, g.card_last4, g.purchase_anchor::text, g.total_installments::text, g.description_key, g.merchant_normalized)) purchase_key
 FROM grouped g
 JOIN finance.number_series n ON n.n<=least(g.total_installments, 60)
 WHERE g.standard_amount IS NOT NULL
), placed AS MATERIALIZED (
 SELECT s.*, obs.transaction_id observed_transaction_id, obs.booking_date observed_booking_date,
  coalesce(obs.bill_post_date, obs.booking_date) observed_posting_date,
  CASE WHEN obs.transaction_id IS NULL THEN 'inferred' ELSE 'observed' END origin,
  src.payment_source_id, src.bill_group_id,
  coalesce(official_bill.closing_date, bill.closing_date) bill_closing_date,
  coalesce(official_bill.due_date, bill.due_date) bill_due_date,
  coalesce(official_bill.id, bill.bill_id) bill_id
 FROM series s
 LEFT JOIN LATERAL (
  SELECT o.transaction_id, o.booking_date, o.bill_id, o.bill_post_date
  FROM observed o
  WHERE o.account_id=s.account_id AND o.card_last4=s.card_last4 AND o.purchase_anchor=s.purchase_anchor
   AND o.total_installments=s.total_installments AND o.description_key=s.description_key
   AND o.merchant_normalized=s.merchant_normalized AND o.installment_number=s.installment_number
  ORDER BY o.transaction_id LIMIT 1
 ) obs ON true
 LEFT JOIN LATERAL (
  SELECT ch.id payment_source_id, coalesce(ch.parent_id, ch.id) bill_group_id,
   coalesce(ch.closing_day, parent.closing_day)::int closing_day, coalesce(ch.due_day, parent.due_day)::int due_day
  FROM finance.payment_sources ch
  LEFT JOIN finance.payment_sources parent ON parent.id=ch.parent_id
  WHERE ch.active AND ch.account_id=s.account_id AND ch.kind='credit'
   AND (ch.card_last4=nullif(s.card_last4,'') OR (ch.card_last4 IS NULL AND ch.parent_id IS NULL))
  ORDER BY (ch.card_last4 IS NOT NULL AND ch.card_last4=nullif(s.card_last4,'')) DESC
  LIMIT 1
 ) src ON true
 LEFT JOIN finance.credit_card_bills official_bill ON official_bill.id=obs.bill_id AND official_bill.account_id=s.account_id
 LEFT JOIN LATERAL finance.assign_bill_cycle(
  coalesce(obs.bill_post_date, obs.booking_date, s.posting_date), s.account_id, src.closing_day, src.due_day
 ) bill ON official_bill.id IS NULL
)
SELECT purchase_key, account_id, nullif(card_last4,'') card_last4, payment_source_id, bill_group_id,
 merchant_name, description, purchase_anchor purchase_date, installment_number, total_installments,
 installment_amount, purchase_total, installments_posted, (total_installments-installments_posted) installments_remaining,
 coalesce(observed_posting_date, posting_date) posting_date, bill_closing_date, bill_due_date, bill_id, origin, observed_transaction_id, observed_booking_date,
 max(coalesce(bill_due_date, observed_posting_date, posting_date)) OVER (PARTITION BY purchase_key) ends_on
FROM placed;


CREATE VIEW finance.current_invoice WITH (security_invoker=true) AS
WITH groups AS MATERIALIZED (
 SELECT ps.id source_id, ps.slug, ps.name source_name, b.name bank_name, ps.account_id, a.pluggy_id pluggy_account_id,
  ps.closing_day::int closing_day, ps.due_day::int due_day, a.balance, a.balance_observed_at
 FROM finance.payment_sources ps
 JOIN finance.banks b ON b.id=ps.bank_id
 LEFT JOIN finance.accounts a ON a.id=ps.account_id
 WHERE ps.kind='credit' AND ps.parent_id IS NULL AND ps.active
), opened AS MATERIALIZED (
 SELECT g.*, c.closing_date open_closing_date, c.due_date open_due_date, c.bill_id open_bill_id
 FROM groups g
 LEFT JOIN LATERAL finance.open_bill_cycle(g.account_id, g.closing_day, g.due_day, finance.today_sp()) c ON true
), future AS MATERIALIZED (
 SELECT o.source_id, coalesce(sum(s.installment_amount),0)::numeric(14,2) future_installments_amount
 FROM opened o
 LEFT JOIN finance.installment_schedule s ON s.account_id=o.account_id AND o.open_closing_date IS NOT NULL AND s.bill_closing_date>o.open_closing_date
 GROUP BY o.source_id
), processing AS MATERIALIZED (
 SELECT o.source_id, coalesce(sum(e.pending_commitment_amount),0)::numeric(14,2) processing_amount
 FROM opened o
 LEFT JOIN finance.transactions_enriched e ON e.account_id=o.account_id AND e.is_effective AND e.status='pending'
  AND e.account_type='CREDIT' AND e.pending_commitment_amount>0
  AND NOT EXISTS (
   SELECT 1 FROM finance.installment_schedule s
   WHERE s.observed_transaction_id=e.id AND o.open_closing_date IS NOT NULL AND s.bill_closing_date>o.open_closing_date
  )
 GROUP BY o.source_id
)
SELECT o.source_id, o.slug, o.bank_name, o.source_name, o.account_id, o.pluggy_account_id,
 coalesce(o.balance,0)::numeric(14,2) pluggy_credit_balance,
 f.future_installments_amount, p.processing_amount,
 (coalesce(o.balance,0)-f.future_installments_amount-p.processing_amount)::numeric(14,2) current_amount,
 o.open_closing_date, o.open_due_date, o.open_bill_id, o.balance_observed_at,
 (o.account_id IS NULL OR o.balance IS NULL) balance_missing
FROM opened o
JOIN future f ON f.source_id=o.source_id
JOIN processing p ON p.source_id=o.source_id;


CREATE VIEW finance.income_occurrences WITH (security_invoker=true) AS
WITH due AS MATERIALIZED (
 SELECT min(open_due_date) allowance_due_date FROM finance.current_invoice
), months AS MATERIALIZED (
 SELECT (date_trunc('month', finance.today_sp())+((n.n-2)*interval '1 month'))::date month_start
 FROM finance.number_series n WHERE n.n<=20
), plans AS MATERIALIZED (
 SELECT 'plan'::text source, e.id income_id, e.name, e.kind, e.periodicity, e.amount, m.month_start,
  CASE
   WHEN e.periodicity='once' THEN e.starts_on
   WHEN e.day_of_month IS NOT NULL THEN finance.clamp_month_day(m.month_start, e.day_of_month::int)
   ELSE NULL END credit_date
 FROM finance.income_entries e
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
), tx AS MATERIALIZED (
 SELECT 'transaction'::text source, e.id income_id, e.description name, 'one_off'::text kind, 'once'::text periodicity,
  e.signed_amount amount, date_trunc('month', e.report_date)::date month_start, e.report_date credit_date
 FROM finance.transactions_enriched e
 WHERE e.is_effective AND e.economic_type='income' AND e.signed_amount>0
  AND NOT EXISTS (
   SELECT 1 FROM finance.income_entries p WHERE p.active AND p.transaction_id=e.id
  )
  AND NOT EXISTS (
   SELECT 1 FROM finance.income_entries p
   WHERE p.active AND p.kind='fixed' AND abs(p.amount-e.signed_amount)<=0.01
    AND e.report_date>=date_trunc('month', e.report_date)::date
    AND e.report_date<(date_trunc('month', e.report_date)+interval '1 month')::date
  )
), rows AS MATERIALIZED (
 SELECT * FROM plans UNION ALL SELECT * FROM tx
)
SELECT r.source, r.income_id, r.name, r.kind, r.periodicity, r.amount::numeric(14,2) amount, r.month_start, r.credit_date,
 (
  r.month_start=date_trunc('month', finance.today_sp())::date AND d.allowance_due_date IS NOT NULL AND (
   (r.credit_date IS NOT NULL AND r.credit_date<=d.allowance_due_date AND r.credit_date>=r.month_start)
   OR (r.credit_date IS NULL AND date_trunc('month', d.allowance_due_date)>r.month_start)
  )
 ) in_vale
FROM rows r CROSS JOIN due d;


CREATE VIEW finance.recurring_charges WITH (security_invoker=true) AS
SELECT o.id, o.label, o.status IN ('active','ending','cancel_requested') active, o.status,
 o.expected_amount amount, o.expected_day debit_day, o.payment_source_id, o.account_id, o.card_last4,
 o.periodicity, o.effective_date starts_on, o.end_date ends_on, o.merchant_pattern, o.notes
FROM finance.recurring_overrides o;


CREATE VIEW finance.pluggy_sync_status WITH (security_invoker=true) AS
SELECT b.id bank_id, b.name bank_name, i.id item_id, h.item_pluggy_id, h.institution_name,
 h.item_status, h.execution_status, h.last_updated_at, h.last_sync_started_at, h.last_sync_finished_at,
 h.last_sync_status, h.pending_webhooks
FROM finance.sync_health h
JOIN finance.items i ON i.pluggy_id=h.item_pluggy_id
LEFT JOIN LATERAL (
 SELECT bk.id, bk.name FROM finance.banks bk
 WHERE bk.slug=lower(i.institution_slug) OR lower(bk.name)=lower(i.institution_name)
 ORDER BY (bk.slug=lower(i.institution_slug)) DESC, bk.slug
 LIMIT 1
) b ON true;


CREATE VIEW finance.payment_source_review WITH (security_invoker=true) AS
SELECT 'payment_source'::text object_type, ps.id object_id, ps.slug, 'sem_conta_pluggy'::text issue,
 'Nenhuma conta Pluggy única casou com o banco e, no crédito, com o final do cartão.' detail
FROM finance.payment_sources ps WHERE ps.active AND ps.account_id IS NULL
UNION ALL
SELECT 'payment_source', ps.id, ps.slug, 'ciclo_nao_informado',
 'Informe closing_day e due_day. Se o vencimento for no mês seguinte, due_day < closing_day.'
FROM finance.payment_sources ps
WHERE ps.active AND ps.kind='credit' AND ps.parent_id IS NULL AND (ps.closing_day IS NULL OR ps.due_day IS NULL)
UNION ALL
SELECT 'recurring', o.id, o.label, 'valor_ou_dia_ausente',
 'Sem valor ou dia a recorrência não entra na projeção do mês.'
FROM finance.recurring_overrides o
WHERE o.status IN ('active','ending','cancel_requested') AND (o.expected_amount IS NULL OR o.expected_day IS NULL)
UNION ALL
SELECT 'income', e.id, e.name, 'dia_nao_informado',
 'Sem dia, a entrada só entra no vale quando o vencimento da fatura aberta cai num mês seguinte.'
FROM finance.income_entries e
WHERE e.active AND e.kind='fixed' AND e.periodicity='monthly' AND e.day_of_month IS NULL
UNION ALL
SELECT 'income', NULL::uuid, '13º / PLR', 'valor_nao_informado',
 'Não há valor nem mês confiável. Inserir em income_entries com periodicity yearly quando souber.'
WHERE NOT EXISTS (SELECT 1 FROM finance.income_entries e WHERE e.name IN ('13º salário','PLR') AND e.amount IS NOT NULL);


CREATE VIEW finance.cashflow_month WITH (security_invoker=true) AS
WITH today AS MATERIALIZED (
 SELECT finance.today_sp() AS as_of,
  date_trunc('month', finance.today_sp())::date month_start,
  (date_trunc('month', finance.today_sp())+interval '1 month - 1 day')::date month_end
), invoice AS MATERIALIZED (
 SELECT coalesce(sum(pluggy_credit_balance),0)::numeric(14,2) pluggy_credit_balance,
  coalesce(sum(future_installments_amount),0)::numeric(14,2) future_installments_amount,
  coalesce(sum(processing_amount),0)::numeric(14,2) processing_amount,
  coalesce(sum(current_amount),0)::numeric(14,2) invoice_current,
  min(open_due_date) allowance_due_date
 FROM finance.current_invoice
), recurring AS MATERIALIZED (
 SELECT coalesce(sum(o.expected_amount),0)::numeric(14,2) recurring_remaining
 FROM finance.recurring_overrides o
 LEFT JOIN finance.payment_sources recurring_source ON recurring_source.id=o.payment_source_id
 CROSS JOIN today t
 CROSS JOIN LATERAL (
  SELECT finance.clamp_month_day(t.month_start, o.expected_day) occurrence
 ) d
 WHERE o.status IN ('active','ending','cancel_requested')
  AND o.expected_amount IS NOT NULL AND o.expected_day IS NOT NULL
  AND o.periodicity='monthly'
  AND d.occurrence BETWEEN t.as_of AND t.month_end
  AND (o.effective_date IS NULL OR d.occurrence>=o.effective_date)
  AND (o.end_date IS NULL OR d.occurrence<=o.end_date)
  AND NOT EXISTS (
   SELECT 1 FROM finance.transactions_enriched e
   WHERE e.is_effective AND e.status IN ('posted','pending') AND e.counts_as_expense
    AND e.report_date BETWEEN t.month_start AND t.month_end
    AND e.merchant_normalized ~ o.merchant_pattern
    AND abs(e.expense_amount-o.expected_amount)<=greatest(abs(o.expected_amount)*0.15, 0.01)
    AND (coalesce(o.account_id, recurring_source.account_id) IS NULL
      OR e.account_id=coalesce(o.account_id, recurring_source.account_id))
    AND (coalesce(o.card_last4, recurring_source.card_last4) IS NULL
      OR e.card_last4=coalesce(o.card_last4, recurring_source.card_last4))
  )
), income AS MATERIALIZED (
 SELECT coalesce(sum(amount),0)::numeric(14,2) incomes_before_due
 FROM finance.income_occurrences WHERE in_vale
), goal AS MATERIALIZED (
 SELECT coalesce(sum(amount),0)::numeric(14,2) savings_goal
 FROM finance.savings_goals g CROSS JOIN today t
 WHERE g.active AND g.starts_on<=t.as_of AND (g.ends_on IS NULL OR g.ends_on>=t.as_of)
)
SELECT t.as_of, t.month_start, t.month_end, i.allowance_due_date,
 i.pluggy_credit_balance, i.future_installments_amount, i.processing_amount, i.invoice_current,
 r.recurring_remaining,
 (i.invoice_current+i.processing_amount+r.recurring_remaining)::numeric(14,2) projected_amount,
 n.incomes_before_due, g.savings_goal,
 (n.incomes_before_due-g.savings_goal-(i.invoice_current+i.processing_amount+r.recurring_remaining))::numeric(14,2) vale_amount,
 (t.month_end-t.as_of+1)::int remaining_days,
 round((n.incomes_before_due-g.savings_goal-(i.invoice_current+i.processing_amount+r.recurring_remaining))/(t.month_end-t.as_of+1), 2)::numeric(14,2) daily_quota
FROM today t CROSS JOIN invoice i CROSS JOIN recurring r CROSS JOIN income n CROSS JOIN goal g;


REVOKE ALL ON finance.expenses, finance.installment_schedule, finance.current_invoice, finance.income_occurrences, finance.recurring_charges, finance.pluggy_sync_status, finance.payment_source_review, finance.cashflow_month FROM PUBLIC, anon, authenticated;


DO $cashflow_reader_policies$
DECLARE n text;
BEGIN
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='dashboard_reader') THEN
  GRANT USAGE ON SCHEMA finance TO dashboard_reader;
  GRANT EXECUTE ON FUNCTION finance.today_sp(), finance.posting_closing_date(date, integer), finance.open_closing_date(date, integer), finance.cycle_due_date(date, integer, integer), finance.clamp_month_day(date, integer), finance.assign_bill_cycle(date, uuid, integer, integer), finance.open_bill_cycle(uuid, integer, integer, date) TO dashboard_reader;
  FOR n IN SELECT tablename FROM pg_tables WHERE schemaname='finance' LOOP
   EXECUTE format('GRANT SELECT ON finance.%I TO dashboard_reader', n);
   EXECUTE format('DROP POLICY IF EXISTS dashboard_reader_select ON finance.%I', n);
   EXECUTE format('CREATE POLICY dashboard_reader_select ON finance.%I FOR SELECT TO dashboard_reader USING (true)', n);
  END LOOP;
  FOR n IN SELECT viewname FROM pg_views WHERE schemaname='finance' LOOP
   EXECUTE format('GRANT SELECT ON finance.%I TO dashboard_reader', n);
  END LOOP;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN
  GRANT SELECT ON finance.number_series, finance.expenses, finance.installment_schedule, finance.current_invoice, finance.income_occurrences, finance.recurring_charges, finance.pluggy_sync_status, finance.payment_source_review, finance.cashflow_month TO finance_reader;
  GRANT EXECUTE ON FUNCTION finance.today_sp(), finance.posting_closing_date(date, integer), finance.open_closing_date(date, integer), finance.cycle_due_date(date, integer, integer), finance.clamp_month_day(date, integer), finance.assign_bill_cycle(date, uuid, integer, integer), finance.open_bill_cycle(uuid, integer, integer, date) TO finance_reader;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
  GRANT SELECT ON finance.number_series, finance.expenses, finance.installment_schedule, finance.current_invoice, finance.income_occurrences, finance.recurring_charges, finance.pluggy_sync_status, finance.payment_source_review, finance.cashflow_month TO service_role;
  GRANT EXECUTE ON FUNCTION finance.today_sp(), finance.posting_closing_date(date, integer), finance.open_closing_date(date, integer), finance.cycle_due_date(date, integer, integer), finance.clamp_month_day(date, integer), finance.assign_bill_cycle(date, uuid, integer, integer), finance.open_bill_cycle(uuid, integer, integer, date) TO service_role;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT USAGE ON SCHEMA finance TO supabase_read_only_user;
  GRANT SELECT ON finance.number_series, finance.expenses, finance.installment_schedule, finance.current_invoice, finance.income_occurrences, finance.recurring_charges, finance.pluggy_sync_status, finance.payment_source_review, finance.cashflow_month TO supabase_read_only_user;
  DROP POLICY IF EXISTS supabase_read_only_select ON finance.number_series;
  CREATE POLICY supabase_read_only_select ON finance.number_series FOR SELECT TO supabase_read_only_user USING (true);
  GRANT EXECUTE ON FUNCTION finance.today_sp(), finance.posting_closing_date(date, integer), finance.open_closing_date(date, integer), finance.cycle_due_date(date, integer, integer), finance.clamp_month_day(date, integer), finance.assign_bill_cycle(date, uuid, integer, integer), finance.open_bill_cycle(uuid, integer, integer, date) TO supabase_read_only_user;
 END IF;
END $cashflow_reader_policies$;
