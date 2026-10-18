CREATE OR REPLACE VIEW finance.dashboard_cashflow WITH (security_invoker=true) AS
SELECT c.*, (projected_amount+savings_goal)::numeric(14,2) committed_amount,
 greatest(0,least(1,projected_amount/greatest(incomes_before_due-savings_goal,1))) envelope_progress
FROM finance.cashflow_month c;
CREATE OR REPLACE VIEW finance.dashboard_monthly WITH (security_invoker=true) AS
SELECT report_month, sum(posted_expense) posted, sum(pending_commitment) pending,
 sum(posted_expense+pending_commitment) committed, sum(transaction_count) transaction_count
FROM finance.monthly_expenses_by_category GROUP BY report_month;
CREATE OR REPLACE VIEW finance.dashboard_categories WITH (security_invoker=true) AS
SELECT c.*, (posted_expense+pending_commitment)::numeric(14,2) committed,
 sum(posted_expense+pending_commitment) OVER (PARTITION BY report_month) total_committed
FROM finance.monthly_expenses_by_category c;
CREATE OR REPLACE VIEW finance.dashboard_merchants WITH (security_invoker=true) AS
SELECT m.*, (posted_expense+pending_commitment)::numeric(14,2) committed
FROM finance.monthly_expenses_by_merchant m;
CREATE OR REPLACE VIEW finance.dashboard_daily WITH (security_invoker=true) AS
SELECT report_month, report_date AS day, sum(posted_expense_amount) posted,
 sum(pending_commitment_amount) pending,
 sum(posted_expense_amount+pending_commitment_amount) committed
FROM finance.transactions_enriched WHERE counts_as_expense AND is_effective GROUP BY report_month,report_date;
CREATE OR REPLACE VIEW finance.dashboard_subscriptions WITH (security_invoker=true) AS
SELECT r.id,r.label,r.status,r.expected_amount,a.name account_name,r.expected_day
FROM finance.recurring_overrides r LEFT JOIN finance.accounts a ON a.id=r.account_id
WHERE r.status IN ('active','ending','cancel_requested')
 AND (r.effective_date IS NULL OR r.effective_date<=finance.today_sp())
 AND (r.end_date IS NULL OR r.end_date>=finance.today_sp());
CREATE OR REPLACE VIEW finance.dashboard_subscription_total WITH (security_invoker=true) AS
SELECT coalesce(sum(expected_amount),0)::numeric(14,2) total FROM finance.dashboard_subscriptions;
CREATE OR REPLACE VIEW finance.dashboard_installments WITH (security_invoker=true) AS
SELECT f.*, a.name account_name,
 sum(estimated_remaining_amount) OVER (PARTITION BY f.account_id,f.card_last4) group_remaining
FROM finance.future_installments f LEFT JOIN finance.accounts a ON a.id=f.account_id WHERE remaining_installments>0;
CREATE OR REPLACE VIEW finance.dashboard_installment_total WITH (security_invoker=true) AS
SELECT coalesce(sum(estimated_remaining_amount),0)::numeric(14,2) total,
 coalesce(sum(remaining_installments),0) remaining_count FROM finance.dashboard_installments;
GRANT SELECT ON finance.dashboard_cashflow,finance.dashboard_monthly,finance.dashboard_categories,
 finance.dashboard_merchants,finance.dashboard_daily,finance.dashboard_subscriptions,
 finance.dashboard_subscription_total,finance.dashboard_installments,finance.dashboard_installment_total TO finance_reader,service_role;
