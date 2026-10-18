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
), recurring_processing AS MATERIALIZED (
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
), manual_tx AS MATERIALIZED (
 SELECT e.account_id, e.expense_amount, t.created_at
 FROM finance.transactions_enriched e
 JOIN finance.transactions t ON t.id=e.id
 WHERE e.source='manual' AND e.deleted_at IS NULL AND e.is_effective
  AND e.status IN ('posted','pending') AND e.counts_as_expense
  AND e.report_date>=date_trunc('month', finance.today_sp())::date
  AND e.report_date<=finance.today_sp()
  AND e.account_id IS NOT NULL
  
), manual_unmatched AS MATERIALIZED (
 SELECT o.source_id, coalesce(sum(e.expense_amount),0)::numeric(14,2) manual_unmatched_amount
 FROM opened o
 LEFT JOIN manual_tx e ON e.account_id=o.account_id
  AND (o.balance_observed_at IS NULL OR e.created_at>o.balance_observed_at)
 GROUP BY o.source_id
)
SELECT o.source_id, o.slug, o.bank_name, o.source_name, o.account_id, o.pluggy_account_id,
 coalesce(o.balance,0)::numeric(14,2) pluggy_credit_balance,
 f.future_installments_amount, (p.processing_amount+m.manual_unmatched_amount)::numeric(14,2) processing_amount,
 (coalesce(o.balance,0)-f.future_installments_amount-p.processing_amount)::numeric(14,2) current_amount,
 o.open_closing_date, o.open_due_date, o.open_bill_id, o.balance_observed_at,
 (o.account_id IS NULL OR o.balance IS NULL) balance_missing,
 l.total_limit, l.available_limit, l.used_limit, l.read_at,
 m.manual_unmatched_amount
FROM opened o
JOIN future f ON f.source_id=o.source_id
JOIN recurring_processing p ON p.source_id=o.source_id
JOIN manual_unmatched m ON m.source_id=o.source_id
LEFT JOIN finance.credit_limits l ON l.source_id=o.source_id;



CREATE OR REPLACE FUNCTION finance.reconcile_pending(p_manual_id uuid DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance,extensions AS $$
DECLARE m record; best record; n int:=0; v_status text;
BEGIN
 FOR m IN SELECT t.*,coalesce(c.last4,t.raw->>'card_last4') wanted_last4,
   coalesce(t.purchase_date,t.booking_date) report_date FROM finance.transactions t LEFT JOIN finance.cards c ON c.id=t.card_id
   WHERE t.source='manual' AND t.deleted_at IS NULL AND (p_manual_id IS NULL OR t.id=p_manual_id)
   AND NOT EXISTS(SELECT 1 FROM finance.reconciliations r WHERE r.manual_tx_id=t.id AND r.status='active')
   AND NOT EXISTS(SELECT 1 FROM finance.reconciliations r WHERE r.manual_tx_id=t.id AND r.status='suggested' AND r.ended_at IS NULL)
 LOOP
  WITH candidates AS (
   SELECT p.id,p.pluggy_id,
    (CASE WHEN abs(p.signed_amount-m.signed_amount)<=0.01 THEN .45 ELSE 0 END +
     CASE WHEN abs(coalesce(p.purchase_date,p.booking_date)-m.report_date)=0 THEN .25 ELSE .15 END +
     .30*finance.merchant_match_score(p.merchant_normalized,m.merchant_normalized))::numeric score,
    count(*) OVER() candidate_count
   FROM finance.transactions p LEFT JOIN finance.cards pc ON pc.id=p.card_id
   WHERE p.source='pluggy' AND p.deleted_at IS NULL AND p.normalization_status='ready'
    AND (m.account_id IS NULL OR p.account_id=m.account_id)
    AND abs(p.signed_amount-m.signed_amount)<=.01
    AND abs(coalesce(p.purchase_date,p.booking_date)-m.report_date)<=3
    AND sign(p.signed_amount)=sign(m.signed_amount)
    AND (m.wanted_last4 IS NULL OR pc.last4=m.wanted_last4)
    AND (finance.merchant_match_score(p.merchant_normalized,m.merchant_normalized)>=.35 OR
      (coalesce(p.purchase_date,p.booking_date)=m.report_date AND NOT EXISTS(
       SELECT 1 FROM finance.transactions p2 WHERE p2.source='pluggy' AND p2.id<>p.id AND p2.deleted_at IS NULL
        AND (m.account_id IS NULL OR p2.account_id=m.account_id)
        AND abs(p2.signed_amount-m.signed_amount)<=.01 AND coalesce(p2.purchase_date,p2.booking_date)=m.report_date)))
    AND NOT EXISTS(SELECT 1 FROM finance.reconciliations r WHERE r.pluggy_tx_id=p.id AND r.status='active')
    AND NOT EXISTS(SELECT 1 FROM finance.reconciliations r WHERE r.manual_tx_id=m.id AND r.pluggy_tx_id=p.id)
    AND NOT (coalesce(p.total_installments,1)>1 AND (m.raw->>'is_total_purchase')::boolean IS TRUE)
  ), ranked AS (
   SELECT candidates.*,lead(score) OVER (ORDER BY score DESC,id) second_score FROM candidates
  )
  SELECT * INTO best FROM ranked ORDER BY score DESC,id LIMIT 1;
  IF best.id IS NOT NULL THEN
   v_status:=CASE WHEN best.second_score IS NULL OR best.score-best.second_score>.15 THEN 'active' ELSE 'suggested' END;
   INSERT INTO finance.reconciliations(manual_tx_id,pluggy_tx_id,status,score,method,evidence)
   VALUES(m.id,best.id,v_status,least(best.score,1),'auto',jsonb_build_object('rule','amount_date_merchant_v1'))
   ON CONFLICT DO NOTHING; n:=n+1;
  END IF;
 END LOOP; RETURN n;
END $$;
