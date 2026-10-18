CREATE OR REPLACE VIEW finance.credit_limits WITH (security_invoker=true) AS
SELECT ps.slug,
 coalesce(a.credit_limit,(a.raw#>>'{creditData,creditLimit}')::numeric)::numeric(14,2) total_limit,
 coalesce(a.available_credit_limit,(a.raw#>>'{creditData,availableCreditLimit}')::numeric)::numeric(14,2) available_limit,
 a.balance::numeric(14,2) used_limit,
 coalesce(a.balance_observed_at,a.updated_at) read_at,
 ps.id source_id, a.id account_id, b.name bank_name
FROM finance.payment_sources ps
JOIN finance.banks b ON b.id=ps.bank_id
LEFT JOIN finance.accounts a ON a.id=ps.account_id AND a.type='CREDIT' AND a.deleted_at IS NULL
WHERE ps.kind='credit' AND ps.parent_id IS NULL AND ps.active;


CREATE OR REPLACE VIEW finance.current_invoice WITH (security_invoker=true) AS
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
 SELECT o.source_id, coalesce((
  SELECT sum(r.expected_amount)
  FROM finance.recurring_overrides r
  JOIN finance.payment_sources ps ON ps.id=r.payment_source_id
  CROSS JOIN LATERAL (
   SELECT finance.clamp_month_day(date_trunc('month', finance.today_sp())::date, r.expected_day) AS occurrence
  ) d
  WHERE r.status IN ('active','ending','cancel_requested')
   AND r.expected_amount IS NOT NULL AND r.expected_day IS NOT NULL AND r.periodicity='monthly'
   AND coalesce(r.account_id, ps.account_id)=o.account_id
   AND d.occurrence<finance.today_sp()
   AND d.occurrence>=date_trunc('month', finance.today_sp())::date
   AND (r.effective_date IS NULL OR d.occurrence>=r.effective_date)
   AND (r.end_date IS NULL OR d.occurrence<=r.end_date)
   AND NOT EXISTS (
    SELECT 1 FROM finance.transactions_enriched e
    WHERE e.is_effective AND e.status IN ('posted','pending') AND e.counts_as_expense
     AND e.report_date>=date_trunc('month', finance.today_sp())::date
     AND e.report_date<(date_trunc('month', finance.today_sp())+interval '1 month')::date
     AND e.merchant_normalized~r.merchant_pattern
     AND abs(e.expense_amount-r.expected_amount)<=greatest(abs(r.expected_amount)*0.15, 0.01)
     AND e.account_id=o.account_id
     AND (coalesce(r.card_last4, ps.card_last4) IS NULL OR e.card_last4=coalesce(r.card_last4, ps.card_last4))
   )
 ),0)::numeric(14,2) processing_amount
 FROM opened o
)
SELECT o.source_id, o.slug, o.bank_name, o.source_name, o.account_id, o.pluggy_account_id,
 coalesce(o.balance,0)::numeric(14,2) pluggy_credit_balance,
 f.future_installments_amount, p.processing_amount,
 (coalesce(o.balance,0)-f.future_installments_amount-p.processing_amount)::numeric(14,2) current_amount,
 o.open_closing_date, o.open_due_date, o.open_bill_id, o.balance_observed_at,
 (o.account_id IS NULL OR o.balance IS NULL) balance_missing,
 l.total_limit, l.available_limit, l.used_limit, l.read_at
FROM opened o
JOIN future f ON f.source_id=o.source_id
JOIN processing p ON p.source_id=o.source_id
LEFT JOIN finance.credit_limits l ON l.source_id=o.source_id;


REVOKE ALL ON finance.credit_limits, finance.current_invoice FROM PUBLIC, anon, authenticated;


DO $credit_limit_grants$
DECLARE n text;
BEGIN
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
  GRANT SELECT ON finance.credit_limits, finance.current_invoice TO service_role;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN
  GRANT SELECT ON finance.credit_limits, finance.current_invoice TO finance_reader;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT USAGE ON SCHEMA finance TO supabase_read_only_user;
  GRANT SELECT ON finance.credit_limits, finance.current_invoice TO supabase_read_only_user;
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
END $credit_limit_grants$;
