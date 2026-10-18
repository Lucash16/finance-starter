CREATE INDEX IF NOT EXISTS bills_account_closing_idx
 ON finance.credit_card_bills(account_id,closing_date DESC);



DROP VIEW IF EXISTS finance.bill_cycle_cards;

DROP VIEW IF EXISTS finance.bill_cycles_recent;

DROP VIEW IF EXISTS finance.current_bills;

DROP VIEW IF EXISTS finance.bill_payment_status;

DROP VIEW IF EXISTS finance.bill_payment_evidence;


CREATE TABLE IF NOT EXISTS finance.bill_payment_overrides (
 bill_id uuid PRIMARY KEY REFERENCES finance.credit_card_bills(id) ON DELETE CASCADE,
 status text NOT NULL CHECK(status IN ('open','closed_unpaid','partially_paid','paid','overdue')),
 paid_amount numeric(14,2) NOT NULL CHECK(paid_amount>=0),
 paid_at date,
 source text NOT NULL,
 notes text,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(paid_at IS NULL OR status='paid')
);


DROP TRIGGER IF EXISTS touch_updated_at ON finance.bill_payment_overrides;

CREATE TRIGGER touch_updated_at BEFORE UPDATE ON finance.bill_payment_overrides
 FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at();


CREATE OR REPLACE FUNCTION finance.validate_bill_payment_override() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,finance AS $$
DECLARE v_closing date; v_due date;
BEGIN
 SELECT closing_date,due_date INTO v_closing,v_due FROM finance.credit_card_bills WHERE id=NEW.bill_id;
 IF NEW.status='open' AND coalesce(v_closing,v_due)<=finance.today_sp() THEN
  RAISE EXCEPTION 'open override is only valid for a cycle that has not closed';
 END IF;
 RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS validate_bill_payment_override ON finance.bill_payment_overrides;

CREATE TRIGGER validate_bill_payment_override BEFORE INSERT OR UPDATE ON finance.bill_payment_overrides
 FOR EACH ROW EXECUTE FUNCTION finance.validate_bill_payment_override();


ALTER TABLE finance.bill_payment_overrides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_all ON finance.bill_payment_overrides;

CREATE POLICY service_role_all ON finance.bill_payment_overrides FOR ALL TO service_role USING(true) WITH CHECK(true);

DROP POLICY IF EXISTS finance_reader_select ON finance.bill_payment_overrides;

CREATE POLICY finance_reader_select ON finance.bill_payment_overrides FOR SELECT TO finance_reader USING(true);


DROP VIEW IF EXISTS finance.bill_payment_evidence;

CREATE VIEW finance.bill_payment_evidence WITH (security_invoker=true) AS
WITH RECURSIVE
active_credit AS (
 SELECT a.id account_id,a.item_id,i.institution_slug
 FROM finance.accounts a JOIN finance.items i ON i.id=a.item_id
 WHERE a.type='CREDIT' AND a.deleted_at IS NULL AND i.enabled
), unique_item_credit AS (
 SELECT item_id,min(account_id::text)::uuid account_id FROM active_credit GROUP BY item_id HAVING count(*)=1
), unique_nubank_credit AS (
 SELECT min(account_id::text)::uuid account_id FROM active_credit
 WHERE lower(institution_slug)='nubank' HAVING count(*)=1
), tx_base AS (
 SELECT t.id,t.pluggy_id,t.account_id,a.item_id,t.booking_date,abs(t.signed_amount)::numeric(14,2) amount,
        t.pluggy_type,t.signed_amount,t.classification_reason
 FROM finance.transactions t JOIN finance.accounts a ON a.id=t.account_id
 WHERE t.source='pluggy' AND t.deleted_at IS NULL AND t.normalization_status='ready'
   AND t.currency='BRL' AND t.status='posted' AND coalesce(t.economic_type_override,t.economic_type)='card_payment'
), raw_evidence AS (
 SELECT c.account_id,'tx:'||x.id::text evidence_id,x.booking_date payment_date,x.amount,'card_credit'::text source,
        x.id::text original_id,'transaction'::text match_reason
 FROM tx_base x JOIN active_credit c ON c.account_id=x.account_id
 WHERE x.pluggy_type='CREDIT' AND x.signed_amount>0
 UNION ALL
 SELECT b.account_id,'array:'||b.id::text||':'||coalesce(p.v->>'id',p.n::text),
        CASE WHEN coalesce(p.v->>'paymentDate','') ~ '^\d{4}-\d{2}-\d{2}' THEN left(p.v->>'paymentDate',10)::date END,
        CASE WHEN coalesce(p.v->>'amount','') ~ '^[0-9]+([.][0-9]+)?$' THEN (p.v->>'amount')::numeric(14,2) END,
        'bill_payments',nullif(p.v->>'id',''),'bill payments array'
 FROM finance.credit_card_bills b
 CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(b.payments)='array' THEN b.payments ELSE '[]'::jsonb END) WITH ORDINALITY p(v,n)
 WHERE jsonb_typeof(p.v)='object'
 UNION ALL
 SELECT u.account_id,'tx:'||x.id::text,x.booking_date,x.amount,'bank_debit',x.id::text,'unique credit account in item'
 FROM tx_base x JOIN unique_item_credit u ON u.item_id=x.item_id
 JOIN finance.accounts a ON a.id=x.account_id AND a.type='BANK'
 WHERE x.pluggy_type='DEBIT' AND x.signed_amount<0
 UNION ALL
 SELECT n.account_id,'tx:'||x.id::text,x.booking_date,x.amount,'nubank_pix',x.id::text,'unique active Nubank destination'
 FROM tx_base x CROSS JOIN unique_nubank_credit n JOIN finance.accounts a ON a.id=x.account_id
 WHERE x.pluggy_type='DEBIT' AND x.signed_amount<0 AND x.classification_reason='pix_credito_fatura_nubank'
   AND a.type='CREDIT' AND x.account_id<>n.account_id
), valid AS (
 SELECT * FROM raw_evidence WHERE payment_date IS NOT NULL AND amount IS NOT NULL AND amount>0
), array_id_dedup AS (
 SELECT *,row_number() OVER(PARTITION BY account_id,source,
   CASE WHEN source='bill_payments' AND original_id IS NOT NULL THEN original_id ELSE evidence_id END
   ORDER BY payment_date,evidence_id) id_rn
 FROM valid
), source_dedup AS (
 SELECT *,row_number() OVER(PARTITION BY account_id,source,amount
   ORDER BY payment_date,evidence_id) source_seq
 FROM array_id_dedup WHERE id_rn=1
), anchored AS (
 SELECT s.* FROM source_dedup s
 WHERE NOT EXISTS(SELECT 1 FROM source_dedup p WHERE p.account_id=s.account_id AND p.source=s.source
   AND p.amount=s.amount AND p.payment_date BETWEEN s.payment_date-1 AND s.payment_date
   AND (p.payment_date,p.evidence_id)<(s.payment_date,s.evidence_id))
), prioritized AS (
 SELECT a.*,CASE a.source WHEN 'card_credit' THEN 1 WHEN 'bill_payments' THEN 2 WHEN 'bank_debit' THEN 3 ELSE 4 END priority
 FROM anchored a
), kept AS (
 SELECT p.* FROM prioritized p
 WHERE NOT EXISTS(SELECT 1 FROM prioritized h WHERE h.account_id=p.account_id AND h.priority<p.priority
   AND abs(h.amount-p.amount)<=.01 AND abs(h.payment_date-p.payment_date)<=1)
), corroboration AS (
 SELECT k.account_id,k.evidence_id,k.payment_date,k.amount,k.source,k.match_reason,
  coalesce(jsonb_agg(jsonb_build_object('evidence_id',p.evidence_id,'source',p.source,'payment_date',p.payment_date,'amount',p.amount)
    ORDER BY p.priority,p.payment_date,p.evidence_id) FILTER(WHERE p.evidence_id IS NOT NULL),'[]'::jsonb) corroborating_evidence
 FROM kept k LEFT JOIN prioritized p ON p.account_id=k.account_id AND p.evidence_id<>k.evidence_id
  AND abs(p.amount-k.amount)<=.01 AND abs(p.payment_date-k.payment_date)<=1
 GROUP BY k.account_id,k.evidence_id,k.payment_date,k.amount,k.source,k.match_reason
), bill_windows AS (
 SELECT b.id bill_id,b.account_id,b.closing_date,
  (SELECT min(n.closing_date) FROM finance.credit_card_bills n WHERE n.account_id=b.account_id AND n.closing_date>b.closing_date) next_closing_date,
  count(*) OVER(PARTITION BY b.account_id,b.closing_date) same_closing
 FROM finance.credit_card_bills b
)
SELECT e.account_id,e.evidence_id,e.payment_date,e.amount,e.source,w.bill_id,e.match_reason,e.corroborating_evidence
FROM corroboration e LEFT JOIN bill_windows w ON w.account_id=e.account_id AND w.closing_date IS NOT NULL
 AND w.same_closing=1 AND e.payment_date>w.closing_date
 AND e.payment_date<=coalesce(w.next_closing_date,finance.today_sp())
WHERE w.bill_id IS NOT NULL OR NOT EXISTS(
 SELECT 1 FROM bill_windows x WHERE x.account_id=e.account_id AND x.closing_date IS NOT NULL AND x.same_closing=1
  AND e.payment_date>x.closing_date AND e.payment_date<=coalesce(x.next_closing_date,finance.today_sp())
);


DROP VIEW IF EXISTS finance.bill_payment_status;

CREATE VIEW finance.bill_payment_status WITH (security_invoker=true) AS
WITH windows AS (
 SELECT b.*,(SELECT min(n.closing_date) FROM finance.credit_card_bills n WHERE n.account_id=b.account_id AND n.closing_date>b.closing_date) next_closing_date,
  count(*) OVER(PARTITION BY b.account_id,b.closing_date) same_closing
 FROM finance.credit_card_bills b
), events AS (
 SELECT w.id bill_id,e.payment_date,e.amount,e.source,
  sum(e.amount) OVER(PARTITION BY w.id ORDER BY e.payment_date,e.evidence_id) running_paid
 FROM windows w JOIN finance.bill_payment_evidence e ON e.bill_id=w.id
 WHERE w.total_amount>0 AND w.closing_date IS NOT NULL AND w.same_closing=1
), automatic AS (
 SELECT w.id bill_id,w.account_id,w.pluggy_id,w.due_date,w.closing_date,w.next_closing_date,w.total_amount,w.currency,
  CASE WHEN w.total_amount<=0 THEN 'paid'
       WHEN coalesce(w.closing_date,w.due_date)>finance.today_sp() THEN 'open'
       WHEN coalesce(sum(e.amount),0)>0 AND coalesce(sum(e.amount),0)>=greatest(w.total_amount-1,0) THEN 'paid'
       WHEN w.due_date<finance.today_sp() THEN 'overdue'
       WHEN coalesce(sum(e.amount),0)>0 THEN 'partially_paid' ELSE 'closed_unpaid' END payment_status,
  CASE WHEN w.total_amount<=0 THEN 0 ELSE coalesce(sum(e.amount),0) END::numeric(14,2) paid_amount,
  CASE WHEN w.total_amount>0 THEN min(e.payment_date) FILTER(WHERE e.running_paid>=greatest(w.total_amount-1,0)) END paid_at,
  CASE WHEN w.total_amount<=0 THEN 'no_amount_due' WHEN count(DISTINCT e.source)=1 THEN min(e.source)
       WHEN count(DISTINCT e.source)>1 THEN 'mixed' END payment_source
 FROM windows w LEFT JOIN events e ON e.bill_id=w.id GROUP BY w.id,w.account_id,w.pluggy_id,w.due_date,w.closing_date,w.next_closing_date,w.total_amount,w.currency
)
SELECT a.bill_id,a.account_id,a.pluggy_id,a.due_date,a.closing_date,a.next_closing_date,a.total_amount,a.currency,
 coalesce(o.status,a.payment_status) payment_status,
 coalesce(o.paid_amount,a.paid_amount)::numeric(14,2) paid_amount,
 CASE WHEN o.bill_id IS NOT NULL THEN o.paid_at ELSE a.paid_at END paid_at,
 CASE WHEN o.bill_id IS NOT NULL THEN o.source ELSE a.payment_source END payment_source,
 greatest(a.total_amount-coalesce(o.paid_amount,a.paid_amount),0)::numeric(14,2) amount_due_remaining,
 (o.bill_id IS NOT NULL) has_override
FROM automatic a LEFT JOIN finance.bill_payment_overrides o ON o.bill_id=a.bill_id;


DROP VIEW IF EXISTS finance.current_bills;

CREATE VIEW finance.current_bills WITH (security_invoker=true) AS
WITH active_accounts AS (
 SELECT a.* FROM finance.accounts a JOIN finance.items i ON i.id=a.item_id
 WHERE a.type='CREDIT' AND a.deleted_at IS NULL AND i.enabled
), official_open AS (
 SELECT DISTINCT ON (b.account_id) b.* FROM finance.credit_card_bills b
 WHERE b.closing_date>finance.today_sp() ORDER BY b.account_id,b.closing_date,b.id
), current_cycle AS (
 SELECT a.id account_id,o.id bill_id FROM active_accounts a LEFT JOIN official_open o ON o.account_id=a.id
), closed_cycles AS (
 SELECT b.account_id,b.id bill_id FROM finance.credit_card_bills b JOIN finance.bill_payment_status s ON s.bill_id=b.id
 WHERE coalesce(b.closing_date,b.due_date)<=finance.today_sp()
  AND (b.due_date>=finance.today_sp()-7 OR (s.payment_status<>'paid' AND b.due_date>=finance.today_sp()-60))
), cycles AS (SELECT account_id,bill_id,true is_current FROM current_cycle UNION ALL SELECT account_id,bill_id,false FROM closed_cycles),
card_totals AS (
 SELECT e.account_id,e.bill_id,coalesce(e.card_last4,'não identificado') card_last4,sum(e.expense_amount)::numeric(14,2) card_subtotal
 FROM finance.transactions_enriched e WHERE e.is_effective AND e.account_type='CREDIT' AND e.economic_type<>'card_payment'
 GROUP BY e.account_id,e.bill_id,coalesce(e.card_last4,'não identificado')
), rows AS (
 SELECT c.account_id,c.bill_id,c.is_current,coalesce(t.card_last4,'não identificado') card_last4,coalesce(t.card_subtotal,0)::numeric(14,2) card_subtotal
 FROM cycles c LEFT JOIN card_totals t ON t.account_id=c.account_id AND t.bill_id IS NOT DISTINCT FROM c.bill_id
), totals AS (
 SELECT r.*,sum(r.card_subtotal) OVER(PARTITION BY r.account_id,r.bill_id)::numeric(14,2) computed_account_total FROM rows r
)
SELECT a.id account_id,a.name account_name,t.bill_id,b.pluggy_id,
 CASE WHEN t.is_current THEN 'aberta' WHEN b.due_date>=finance.today_sp() THEN 'fechada_a_vencer' ELSE 'vencida' END bill_status,
 b.due_date,b.closing_date,b.total_amount account_bill_total,coalesce(b.currency,a.currency) currency,
 t.card_last4,t.card_subtotal,t.computed_account_total,
 coalesce(s.payment_status,'open')::text payment_status,coalesce(s.paid_amount,0)::numeric(14,2) paid_amount,s.paid_at,
 s.payment_source,coalesce(s.amount_due_remaining,b.total_amount,0)::numeric(14,2) amount_due_remaining,t.is_current,
 a.balance::numeric(14,2) account_used_limit,a.balance_observed_at account_used_limit_observed_at
FROM totals t JOIN active_accounts a ON a.id=t.account_id LEFT JOIN finance.credit_card_bills b ON b.id=t.bill_id
LEFT JOIN finance.bill_payment_status s ON s.bill_id=t.bill_id;


DROP VIEW IF EXISTS finance.bill_cycles_recent;

CREATE VIEW finance.bill_cycles_recent WITH (security_invoker=true) AS
WITH active_accounts AS (
 SELECT a.* FROM finance.accounts a JOIN finance.items i ON i.id=a.item_id WHERE a.type='CREDIT' AND a.deleted_at IS NULL AND i.enabled
), current_cycle AS (
 SELECT a.id account_id,(SELECT b.id FROM finance.credit_card_bills b WHERE b.account_id=a.id AND b.closing_date>finance.today_sp() ORDER BY b.closing_date,b.id LIMIT 1) bill_id
 FROM active_accounts a
), candidates AS (
 SELECT account_id,bill_id,1 cycle_rank FROM current_cycle
 UNION ALL
 SELECT b.account_id,b.id,1+row_number() OVER(PARTITION BY b.account_id ORDER BY b.closing_date DESC,b.id)::int
 FROM finance.credit_card_bills b WHERE coalesce(b.closing_date,b.due_date)<=finance.today_sp()
), computed AS (
 SELECT e.account_id,e.bill_id,sum(e.expense_amount)::numeric(14,2) total
 FROM finance.transactions_enriched e WHERE e.is_effective AND e.account_type='CREDIT' AND e.economic_type<>'card_payment' GROUP BY e.account_id,e.bill_id
)
SELECT a.id account_id,a.name account_name,c.cycle_rank,c.bill_id,b.pluggy_id,
 CASE WHEN c.cycle_rank=1 THEN 'aberta' WHEN b.due_date>=finance.today_sp() THEN 'fechada_a_vencer' ELSE 'vencida' END bill_status,
 b.closing_date,b.due_date,b.total_amount account_bill_total,coalesce(x.total,0)::numeric(14,2) computed_account_total,
 coalesce(s.payment_status,'open')::text payment_status,coalesce(s.paid_amount,0)::numeric(14,2) paid_amount,s.paid_at,s.payment_source,
 coalesce(s.amount_due_remaining,b.total_amount,0)::numeric(14,2) amount_due_remaining,(c.cycle_rank=1) is_current
FROM candidates c JOIN active_accounts a ON a.id=c.account_id LEFT JOIN finance.credit_card_bills b ON b.id=c.bill_id
LEFT JOIN computed x ON x.account_id=c.account_id AND x.bill_id IS NOT DISTINCT FROM c.bill_id
LEFT JOIN finance.bill_payment_status s ON s.bill_id=c.bill_id WHERE c.cycle_rank<=3;


DROP VIEW IF EXISTS finance.bill_cycle_cards;

CREATE VIEW finance.bill_cycle_cards WITH (security_invoker=true) AS
SELECT c.account_id,c.bill_id,coalesce(e.card_last4,'não identificado') card_last4,
 coalesce(sum(e.expense_amount),0)::numeric(14,2) card_subtotal
FROM finance.bill_cycles_recent c LEFT JOIN finance.transactions_enriched e ON e.account_id=c.account_id
 AND e.bill_id IS NOT DISTINCT FROM c.bill_id AND e.is_effective AND e.account_type='CREDIT' AND e.economic_type<>'card_payment'
GROUP BY c.account_id,c.bill_id,coalesce(e.card_last4,'não identificado');


REVOKE ALL ON finance.bill_payment_overrides,finance.bill_payment_evidence,finance.bill_payment_status,finance.current_bills,finance.bill_cycles_recent,finance.bill_cycle_cards FROM PUBLIC,anon,authenticated;

REVOKE ALL ON FUNCTION finance.validate_bill_payment_override() FROM PUBLIC,anon,authenticated;


DO $bill_payment_security$
BEGIN
 GRANT USAGE ON SCHEMA finance TO service_role,finance_reader;
 GRANT SELECT ON finance.bill_payment_overrides,finance.bill_payment_evidence,finance.bill_payment_status,finance.current_bills,finance.bill_cycles_recent,finance.bill_cycle_cards TO service_role,finance_reader;
 GRANT INSERT,UPDATE,DELETE ON finance.bill_payment_overrides TO service_role;
 GRANT EXECUTE ON FUNCTION finance.today_sp() TO service_role,finance_reader;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT USAGE ON SCHEMA finance TO supabase_read_only_user;
  GRANT SELECT ON finance.bill_payment_overrides,finance.bill_payment_evidence,finance.bill_payment_status,finance.current_bills,finance.bill_cycles_recent,finance.bill_cycle_cards TO supabase_read_only_user;
  GRANT EXECUTE ON FUNCTION finance.today_sp() TO supabase_read_only_user;
  DROP POLICY IF EXISTS supabase_read_only_select ON finance.bill_payment_overrides;
  CREATE POLICY supabase_read_only_select ON finance.bill_payment_overrides FOR SELECT TO supabase_read_only_user USING(true);
 END IF;
END $bill_payment_security$;
