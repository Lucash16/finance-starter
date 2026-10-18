CREATE OR REPLACE VIEW finance.transactions_enriched WITH (security_invoker=true) AS
SELECT t.id,t.source,t.pluggy_id,t.source_key,t.account_id,a.name account_name,a.type account_type,i.institution_name,
 t.card_id,c.last4 card_last4,t.bill_id,t.pluggy_bill_id,t.booking_date,t.purchase_date,t.occurred_at,
 CASE WHEN coalesce(t.total_installments,1)>1 THEN t.booking_date ELSE coalesce(t.purchase_date,t.booking_date) END report_date,
 date_trunc('month',CASE WHEN coalesce(t.total_installments,1)>1 THEN t.booking_date ELSE coalesce(t.purchase_date,t.booking_date) END)::date report_month,
 t.description,t.description_raw,t.merchant_id,coalesce(m.name,t.merchant_normalized,'Não identificado') merchant_name,t.merchant_normalized,
 t.original_amount,t.original_currency,t.amount_in_account_currency,t.signed_amount,t.currency,t.normalization_status,t.pluggy_type,t.status,
 coalesce(t.economic_type_override,t.economic_type) economic_type,t.pluggy_category_id,t.user_category_id,
 coalesce(uc.id,mc.id,nc.id) effective_category_id,coalesce(uc.name,mc.name,nc.name,'Não categorizado') effective_category,
 t.expense_override,t.installment_number,t.total_installments,t.installment_total_amount,t.bill_forecast_month,t.bill_post_date,
 t.provider_created_at,t.provider_updated_at,t.revision_no,t.first_seen_at,t.last_seen_at,t.deleted_at,t.deletion_reason,
 (t.deleted_at IS NOT NULL) is_deleted,
 (t.deleted_at IS NULL AND t.normalization_status='ready' AND NOT(t.source='manual' AND ar.id IS NOT NULL)) is_effective,
 (t.deleted_at IS NULL AND t.normalization_status='ready' AND NOT(t.source='manual' AND ar.id IS NOT NULL)
   AND coalesce(t.expense_override,coalesce(t.economic_type_override,t.economic_type) IN ('expense','refund') AND coalesce(uc.counts_as_expense,mc.counts_as_expense,nc.counts_as_expense,true))) counts_as_expense,
 CASE WHEN t.deleted_at IS NULL AND t.normalization_status='ready' AND NOT(t.source='manual' AND ar.id IS NOT NULL)
   AND coalesce(t.expense_override,coalesce(t.economic_type_override,t.economic_type) IN ('expense','refund') AND coalesce(uc.counts_as_expense,mc.counts_as_expense,nc.counts_as_expense,true))
   THEN -t.signed_amount ELSE 0::numeric END expense_amount,
 CASE WHEN t.status='posted' AND t.deleted_at IS NULL AND t.normalization_status='ready' AND NOT(t.source='manual' AND ar.id IS NOT NULL)
   AND coalesce(t.expense_override,coalesce(t.economic_type_override,t.economic_type) IN ('expense','refund') AND coalesce(uc.counts_as_expense,mc.counts_as_expense,nc.counts_as_expense,true))
   THEN -t.signed_amount ELSE 0::numeric END posted_expense_amount,
 CASE WHEN t.status='pending' AND t.deleted_at IS NULL AND t.normalization_status='ready' AND NOT(t.source='manual' AND ar.id IS NOT NULL)
   AND coalesce(t.expense_override,coalesce(t.economic_type_override,t.economic_type) IN ('expense','refund') AND coalesce(uc.counts_as_expense,mc.counts_as_expense,nc.counts_as_expense,true))
   THEN greatest(-t.signed_amount,0) ELSE 0::numeric END pending_commitment_amount,
 ar.id reconciliation_id,ar.pluggy_tx_id effective_pluggy_tx_id,
 CASE WHEN t.normalization_status='needs_review' THEN 'Moeda sem conversão BRL' WHEN t.source='manual' AND ar.id IS NOT NULL THEN 'Duplicata manual reconciliada' WHEN t.deleted_at IS NOT NULL THEN 'Excluída na origem' END exclusion_reason
FROM finance.transactions t LEFT JOIN finance.accounts a ON a.id=t.account_id LEFT JOIN finance.items i ON i.id=a.item_id
LEFT JOIN finance.cards c ON c.id=t.card_id LEFT JOIN finance.merchants m ON m.id=t.merchant_id
LEFT JOIN finance.category_mappings cm ON cm.pluggy_category_id=t.pluggy_category_id LEFT JOIN finance.categories mc ON mc.id=cm.user_category_id
LEFT JOIN finance.categories uc ON uc.id=t.user_category_id LEFT JOIN finance.categories nc ON nc.slug='nao-categorizado'
LEFT JOIN finance.reconciliations ar ON ar.manual_tx_id=t.id AND ar.status='active';


CREATE OR REPLACE VIEW finance.monthly_expenses_by_category WITH (security_invoker=true) AS
SELECT report_month,effective_category_id,effective_category,sum(posted_expense_amount)::numeric(14,2) posted_expense,
 sum(pending_commitment_amount)::numeric(14,2) pending_commitment,count(*) FILTER(WHERE counts_as_expense) transaction_count
FROM finance.transactions_enriched GROUP BY report_month,effective_category_id,effective_category;

CREATE OR REPLACE VIEW finance.monthly_expenses_by_card WITH (security_invoker=true) AS
SELECT report_month,institution_name,account_id,account_name,coalesce(card_last4,'não identificado') card_last4,
 sum(posted_expense_amount)::numeric(14,2) posted_expense,sum(pending_commitment_amount)::numeric(14,2) pending_commitment
FROM finance.transactions_enriched GROUP BY report_month,institution_name,account_id,account_name,coalesce(card_last4,'não identificado');

CREATE OR REPLACE VIEW finance.monthly_expenses_by_merchant WITH (security_invoker=true) AS
SELECT report_month,merchant_id,merchant_name,sum(posted_expense_amount)::numeric(14,2) posted_expense,
 sum(pending_commitment_amount)::numeric(14,2) pending_commitment,count(*) FILTER(WHERE counts_as_expense) transaction_count
FROM finance.transactions_enriched GROUP BY report_month,merchant_id,merchant_name;


DROP VIEW IF EXISTS finance.current_bills;

CREATE VIEW finance.current_bills WITH (security_invoker=true) AS
WITH card_totals AS (
 SELECT e.account_id,e.bill_id,coalesce(e.card_last4,'não identificado') card_last4,
  sum(e.expense_amount)::numeric(14,2) card_subtotal
 FROM finance.transactions_enriched e
 WHERE e.is_effective AND e.account_type='CREDIT' AND e.economic_type<>'card_payment'
 GROUP BY e.account_id,e.bill_id,coalesce(e.card_last4,'não identificado')
), bill_totals AS (
 SELECT c.*,sum(c.card_subtotal) OVER(PARTITION BY c.account_id,c.bill_id)::numeric(14,2) computed_account_total
 FROM card_totals c
)
SELECT a.id account_id,a.name account_name,t.bill_id,b.pluggy_id,
 CASE WHEN t.bill_id IS NULL THEN 'aberta'
      WHEN b.due_date>=finance.today_sp() THEN 'fechada_a_vencer'
      ELSE 'vencida' END bill_status,
 b.due_date,b.closing_date,b.total_amount account_bill_total,coalesce(b.currency,a.currency) currency,
 t.card_last4,t.card_subtotal,t.computed_account_total
FROM bill_totals t
JOIN finance.accounts a ON a.id=t.account_id
LEFT JOIN finance.credit_card_bills b ON b.id=t.bill_id
WHERE t.bill_id IS NULL OR b.due_date>=finance.today_sp()-7;


DO $current_bills_grants$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
  GRANT SELECT ON finance.current_bills TO service_role;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN
  GRANT SELECT ON finance.current_bills TO finance_reader;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT SELECT ON finance.current_bills TO supabase_read_only_user;
 END IF;
END $current_bills_grants$;


CREATE OR REPLACE VIEW finance.budget_status WITH (security_invoker=true) AS
SELECT b.id,b.name,b.start_date,b.end_date_exclusive,b.amount,b.currency,b.reserve_pending,b.category_id,
 coalesce(sum(e.posted_expense_amount) FILTER(WHERE e.report_date>=b.start_date AND e.report_date<b.end_date_exclusive AND (b.category_id IS NULL OR e.effective_category_id=b.category_id)),0)::numeric(14,2) posted_spend,
 coalesce(sum(e.pending_commitment_amount) FILTER(WHERE b.reserve_pending AND e.report_date>=b.start_date AND e.report_date<b.end_date_exclusive AND (b.category_id IS NULL OR e.effective_category_id=b.category_id)),0)::numeric(14,2) pending_reserved,
 (b.amount-coalesce(sum(e.posted_expense_amount) FILTER(WHERE e.report_date>=b.start_date AND e.report_date<b.end_date_exclusive AND (b.category_id IS NULL OR e.effective_category_id=b.category_id)),0))::numeric(14,2) available_after_posted,
 (b.amount-coalesce(sum(e.posted_expense_amount+CASE WHEN b.reserve_pending THEN e.pending_commitment_amount ELSE 0 END) FILTER(WHERE e.report_date>=b.start_date AND e.report_date<b.end_date_exclusive AND (b.category_id IS NULL OR e.effective_category_id=b.category_id)),0))::numeric(14,2) available_balance
FROM finance.budgets b LEFT JOIN finance.transactions_enriched e ON true WHERE b.active GROUP BY b.id;


CREATE OR REPLACE VIEW finance.future_installments WITH (security_invoker=true) AS
SELECT account_id,card_last4,merchant_name,description,purchase_date,total_installments,max(installment_number) last_observed_installment,
 greatest(total_installments-max(installment_number),0) remaining_installments,
 max(abs(signed_amount))::numeric(14,2) estimated_installment_amount,
 (max(abs(signed_amount))*greatest(total_installments-max(installment_number),0))::numeric(14,2) estimated_remaining_amount,
 'observed_metadata' confidence
FROM finance.transactions_enriched WHERE is_effective AND total_installments>1
GROUP BY account_id,card_last4,merchant_name,description,purchase_date,total_installments;


DROP VIEW IF EXISTS finance.recurring_subscriptions;

CREATE VIEW finance.recurring_subscriptions WITH (security_invoker=true) AS
WITH x AS (SELECT account_id,card_last4,merchant_name,report_date,expense_amount,
 lag(report_date) OVER(PARTITION BY account_id,card_last4,merchant_name ORDER BY report_date) prev_date
 FROM finance.transactions_enriched WHERE is_effective AND status='posted' AND counts_as_expense AND coalesce(total_installments,1)=1), g AS (
 SELECT account_id,card_last4,merchant_name,count(*) occurrences,min(expense_amount) min_amount,max(expense_amount) max_amount,
 max(report_date) last_occurrence,avg(report_date-prev_date) FILTER(WHERE prev_date IS NOT NULL) average_interval_days
 FROM x GROUP BY account_id,card_last4,merchant_name)
SELECT *, (last_occurrence+round(average_interval_days)::int) estimated_next_date FROM g
WHERE occurrences>=3 AND average_interval_days BETWEEN 25 AND 35 AND (max_amount-min_amount)<=greatest(max_amount*.10,.01);


CREATE OR REPLACE VIEW finance.sync_health WITH (security_invoker=true) AS
SELECT i.pluggy_id item_pluggy_id,i.institution_name,i.status item_status,i.execution_status,i.last_updated_at,
 max(s.started_at) last_sync_started_at,max(s.finished_at) last_sync_finished_at,
 (array_agg(s.status ORDER BY s.started_at DESC))[1] last_sync_status,
 count(w.id) FILTER(WHERE w.status IN ('received','failed') OR (w.status='processing' AND w.updated_at<now()-interval '10 minutes')) pending_webhooks
FROM finance.items i LEFT JOIN finance.sync_runs s ON s.item_id=i.id LEFT JOIN finance.webhook_events w ON w.item_pluggy_id=i.pluggy_id
GROUP BY i.id;
