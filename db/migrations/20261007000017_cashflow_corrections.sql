ALTER TABLE finance.payment_sources ADD COLUMN IF NOT EXISTS closing_day_estimated boolean NOT NULL DEFAULT false;

ALTER TABLE finance.income_entries ADD COLUMN IF NOT EXISTS estimated boolean NOT NULL DEFAULT false;


CREATE OR REPLACE FUNCTION finance.last_business_day(p_month date) RETURNS date
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog AS $$
 SELECT CASE extract(dow FROM last_day)::int WHEN 0 THEN (last_day-2) WHEN 6 THEN (last_day-1) ELSE last_day END
 FROM (SELECT (date_trunc('month', p_month)+interval '1 month - 1 day')::date AS last_day) d
$$;





CREATE TABLE IF NOT EXISTS finance.installment_plans (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
 payment_source_id uuid NOT NULL REFERENCES finance.payment_sources(id),
 card_last4 text NOT NULL CHECK (card_last4~'^[0-9]{4}$'),
 merchant_name text NOT NULL,
 merchant_pattern text NOT NULL,
 purchase_date date NOT NULL,
 total_installments integer NOT NULL CHECK (total_installments BETWEEN 2 AND 60),
 installment_amount numeric(14,2) NOT NULL CHECK (installment_amount>=0),
 active boolean NOT NULL DEFAULT true,
 notes text,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (payment_source_id, merchant_pattern, purchase_date, total_installments)
);

CREATE INDEX IF NOT EXISTS installment_plans_source_idx ON finance.installment_plans(payment_source_id);

DROP TRIGGER IF EXISTS touch_updated_at ON finance.installment_plans;

CREATE TRIGGER touch_updated_at BEFORE UPDATE ON finance.installment_plans FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at();



CREATE OR REPLACE FUNCTION finance.is_own_bank_transfer(p_account_id uuid, p_description text, p_payee text, p_signed_amount numeric, p_booking_date date) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,finance,extensions AS $$
 SELECT count(*)=1
 FROM finance.transactions counterpart
 JOIN finance.accounts other ON other.id=counterpart.account_id AND other.type='BANK' AND other.deleted_at IS NULL
 JOIN finance.items oi ON oi.id=other.item_id AND oi.enabled
 JOIN finance.accounts mine ON mine.id=p_account_id AND mine.type='BANK' AND mine.deleted_at IS NULL
 JOIN finance.items mi ON mi.id=mine.item_id AND mi.enabled AND mi.id<>oi.id
 CROSS JOIN LATERAL (
  SELECT lower(extensions.unaccent(coalesce(p_description,'')||' '||coalesce(p_payee,''))) AS txt
 ) s
 WHERE counterpart.deleted_at IS NULL
  AND counterpart.signed_amount=-p_signed_amount
  AND abs(counterpart.booking_date-p_booking_date)<=2
  AND s.txt~'(pix|ted|doc|transf)'
  AND (
   (lower(oi.institution_slug)='nubank' AND s.txt~'(nubank|nu pagamentos|nu pag|nu financeira)')
   OR (lower(oi.institution_slug)='santander' AND s.txt~'santander')
   OR (lower(oi.institution_slug) NOT IN ('nubank','santander') AND s.txt~('\m'||lower(oi.institution_slug)||'\M'))
  )
$$;


CREATE OR REPLACE FUNCTION finance.classify_pluggy(
 p_account_type text,p_pluggy_type text,p_category_id text,p_description text,p_payee text,p_receiver_document text,p_payer_document text
) RETURNS TABLE(economic_type text,category_slug text,reason text)
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,finance,extensions AS $$
DECLARE r finance.classification_rules%ROWTYPE; v_payee text:=finance.normalize_merchant(p_payee); v_desc text:=lower(extensions.unaccent(coalesce(p_description,''))); v_person text;
BEGIN
 FOR r IN SELECT * FROM finance.classification_rules q WHERE q.active AND (q.account_type IS NULL OR q.account_type=p_account_type) ORDER BY q.priority,q.id LOOP
  IF (r.description_regex IS NULL OR v_desc ~ r.description_regex) AND (r.payee_regex IS NULL OR v_payee ~ r.payee_regex) THEN
   economic_type:=r.economic_type; category_slug:=r.category_slug; reason:=r.reason; RETURN NEXT; RETURN;
  END IF;
 END LOOP;
 IF p_account_type='BANK' THEN
  IF (p_pluggy_type='DEBIT' AND (EXISTS(SELECT 1 FROM finance.owner_identities WHERE kind='document' AND value_normalized=regexp_replace(coalesce(p_receiver_document,''),'\D','','g')) OR EXISTS(SELECT 1 FROM finance.owner_identities WHERE kind='name' AND value_normalized=v_payee)))
   OR (p_pluggy_type='CREDIT' AND (EXISTS(SELECT 1 FROM finance.owner_identities WHERE kind='document' AND value_normalized=regexp_replace(coalesce(p_payer_document,''),'\D','','g')) OR EXISTS(SELECT 1 FROM finance.owner_identities WHERE kind='name' AND value_normalized=v_payee))) THEN
   economic_type:='internal_transfer'; category_slug:='transferencias-internas'; reason:='titular_identificado'; RETURN NEXT; RETURN;
  END IF;
  IF v_desc ~ '^pix[[:space:]]+' THEN
   v_person:=finance.normalize_merchant(regexp_replace(v_desc,'^pix[[:space:]]+',''));
   IF length(v_person)>=10 AND EXISTS(SELECT 1 FROM finance.owner_identities WHERE kind='name' AND value_normalized LIKE v_person||'%') THEN
    economic_type:='internal_transfer'; category_slug:='transferencias-internas'; reason:='titular_identificado'; RETURN NEXT; RETURN;
   END IF;
  END IF;
 END IF;
 IF p_account_type='CREDIT' AND p_pluggy_type='DEBIT' AND v_desc ~ '^pix[[:space:]]+' THEN
  v_person:=finance.normalize_merchant(regexp_replace(v_desc,'^pix[[:space:]]+',''));
  IF length(v_person)>=10 AND EXISTS(SELECT 1 FROM finance.owner_identities WHERE kind='name' AND value_normalized LIKE v_person||'%') THEN
   economic_type:='internal_transfer'; category_slug:='transferencias-internas'; reason:='pix_credito_para_si'; RETURN NEXT; RETURN;
  END IF;
 END IF;
 economic_type:=finance.classify_transaction(p_account_type,p_pluggy_type,p_category_id); category_slug:=NULL; reason:='regra_base'; RETURN NEXT;
END $$;


CREATE OR REPLACE FUNCTION finance.apply_transaction_classification() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,finance AS $$
DECLARE c record; a_type text; payee text; base_economic_type text;
BEGIN
 IF NEW.source<>'pluggy' OR NEW.economic_type_override IS NOT NULL THEN RETURN NEW; END IF;
 SELECT type INTO a_type FROM finance.accounts WHERE id=NEW.account_id;
 payee:=CASE WHEN NEW.pluggy_type='CREDIT' THEN coalesce(NEW.raw#>>'{paymentData,payer,name}',NEW.description) ELSE coalesce(NEW.raw#>>'{paymentData,receiver,name}',NEW.description) END;
 SELECT * INTO c FROM finance.classify_pluggy(a_type,NEW.pluggy_type,NEW.pluggy_category_id,NEW.description,payee,NEW.raw#>>'{paymentData,receiver,documentNumber}',NEW.raw#>>'{paymentData,payer,documentNumber}');
 IF a_type='BANK' AND c.economic_type IN ('income','expense') AND finance.is_own_bank_transfer(NEW.account_id, NEW.description, payee, NEW.signed_amount, NEW.booking_date) THEN
  c.economic_type:='internal_transfer'; c.category_slug:='transferencias-internas'; c.reason:='titular_identificado';
 END IF;
 NEW.economic_type:=c.economic_type; NEW.classification_reason:=c.reason;
 base_economic_type:=finance.classify_transaction(a_type,NEW.pluggy_type,NEW.pluggy_category_id);
 IF c.category_slug IS NOT NULL AND (NEW.pluggy_category_id IS NULL OR c.economic_type IS DISTINCT FROM base_economic_type) THEN
  SELECT id INTO NEW.user_category_id FROM finance.categories WHERE slug=c.category_slug;
 END IF;
 RETURN NEW;
END $$;


CREATE OR REPLACE FUNCTION finance.reclassify_own_transfer_pairs() RETURNS integer
LANGUAGE plpgsql SET search_path=pg_catalog,finance AS $$
DECLARE n integer;
BEGIN
 UPDATE finance.transactions t
 SET economic_type='internal_transfer', classification_reason='titular_identificado',
  user_category_id=(SELECT id FROM finance.categories WHERE slug='transferencias-internas')
 FROM finance.accounts a
 WHERE t.account_id=a.id AND a.type='BANK' AND t.source='pluggy' AND t.deleted_at IS NULL
  AND t.economic_type_override IS NULL
  AND (finance.is_own_bank_transfer(
    t.account_id, t.description,
    CASE WHEN t.pluggy_type='CREDIT' THEN coalesce(t.raw#>>'{paymentData,payer,name}',t.description)
     ELSE coalesce(t.raw#>>'{paymentData,receiver,name}',t.description) END,
    t.signed_amount, t.booking_date)
   OR EXISTS (
    SELECT 1 FROM finance.transactions peer
    WHERE peer.deleted_at IS NULL AND peer.signed_amount=-t.signed_amount
     AND abs(peer.booking_date-t.booking_date)<=2
     AND finance.is_own_bank_transfer(
      peer.account_id, peer.description,
      CASE WHEN peer.pluggy_type='CREDIT' THEN coalesce(peer.raw#>>'{paymentData,payer,name}',peer.description)
       ELSE coalesce(peer.raw#>>'{paymentData,receiver,name}',peer.description) END,
      peer.signed_amount, peer.booking_date)
   ))
  AND (t.economic_type, t.classification_reason, t.user_category_id) IS DISTINCT FROM
   ('internal_transfer'::text, 'titular_identificado'::text,
    (SELECT id FROM finance.categories WHERE slug='transferencias-internas'));
 GET DIAGNOSTICS n=ROW_COUNT;
 RETURN n;
END $$;


CREATE OR REPLACE FUNCTION finance.reclassify_own_transfer_pairs_after_statement() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,finance AS $$
BEGIN
 IF pg_trigger_depth()=1 THEN PERFORM finance.reclassify_own_transfer_pairs(); END IF;
 RETURN NULL;
END $$;


DROP TRIGGER IF EXISTS transaction_own_transfer_pairs_insert ON finance.transactions;

CREATE TRIGGER transaction_own_transfer_pairs_insert AFTER INSERT ON finance.transactions
FOR EACH STATEMENT EXECUTE FUNCTION finance.reclassify_own_transfer_pairs_after_statement();

DROP TRIGGER IF EXISTS transaction_own_transfer_pairs_update ON finance.transactions;

CREATE TRIGGER transaction_own_transfer_pairs_update AFTER UPDATE ON finance.transactions
FOR EACH STATEMENT EXECUTE FUNCTION finance.reclassify_own_transfer_pairs_after_statement();


DROP VIEW IF EXISTS finance.cashflow_month;

DROP VIEW IF EXISTS finance.income_occurrences;

DROP VIEW IF EXISTS finance.current_invoice;

DROP VIEW IF EXISTS finance.installment_schedule;

DROP VIEW IF EXISTS finance.payment_source_review;


CREATE VIEW finance.installment_schedule WITH (security_invoker=true) AS
WITH observed AS MATERIALIZED (
 SELECT e.id transaction_id, e.account_id, coalesce(e.card_last4,'') card_last4, e.card_id,
  e.description, e.merchant_name, e.merchant_normalized, e.installment_number, e.total_installments,
  e.installment_total_amount, abs(e.signed_amount)::numeric(14,2) parcel_amount, e.booking_date, e.purchase_date, e.status,
  e.bill_id, e.bill_post_date,
  CASE
   WHEN e.installment_number<=1 THEN coalesce(e.purchase_date, e.booking_date)
   WHEN e.purchase_date IS NOT NULL AND abs(e.booking_date-e.purchase_date)<15
   THEN (e.booking_date-((e.installment_number-1)*interval '1 month'))::date
   WHEN e.purchase_date IS NOT NULL AND e.purchase_date BETWEEN
    (coalesce(e.bill_post_date, e.booking_date)-((e.installment_number-1)*interval '1 month')-interval '45 days')::date
    AND (coalesce(e.bill_post_date, e.booking_date)-((e.installment_number-1)*interval '1 month')+interval '45 days')::date
   THEN e.purchase_date
   ELSE (coalesce(e.bill_post_date, e.booking_date)-((e.installment_number-1)*interval '1 month'))::date
  END purchase_anchor,
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
), manual_src AS MATERIALIZED (
 SELECT p.id plan_id, p.card_last4, p.merchant_name, p.purchase_date, p.total_installments, p.installment_amount,
  (p.installment_amount*p.total_installments)::numeric(14,2) purchase_total,
  ch.account_id, ch.id payment_source_id, coalesce(ch.parent_id, ch.id) bill_group_id,
  coalesce(ch.closing_day, parent.closing_day)::int closing_day, coalesce(ch.due_day, parent.due_day)::int due_day,
  md5('plan|'||p.id::text) purchase_key
 FROM finance.installment_plans p
 JOIN finance.payment_sources ch ON ch.id=p.payment_source_id
 LEFT JOIN finance.payment_sources parent ON parent.id=ch.parent_id
 WHERE p.active AND NOT EXISTS (
  SELECT 1 FROM observed o
  WHERE o.card_last4=p.card_last4 AND o.total_installments=p.total_installments
   AND o.merchant_normalized~*p.merchant_pattern
   AND abs(o.parcel_amount-p.installment_amount)<=greatest(p.installment_amount*0.15, 0.50)
 )
), manual_series AS MATERIALIZED (
 SELECT s.*, n.n installment_number, (s.purchase_date+((n.n-1)*interval '1 month'))::date posting_date
 FROM manual_src s
 JOIN finance.number_series n ON n.n<=s.total_installments
), manual_placed AS MATERIALIZED (
 SELECT s.purchase_key, s.account_id, s.card_last4, s.payment_source_id, s.bill_group_id, s.merchant_name,
  s.merchant_name AS description, s.purchase_date AS purchase_anchor, s.installment_number, s.total_installments,
  s.installment_amount, s.purchase_total, 0 AS installments_posted, s.posting_date, NULL::date AS observed_posting_date,
  bill.closing_date AS bill_closing_date, bill.due_date AS bill_due_date, bill.bill_id,
  'manual'::text AS origin, NULL::uuid AS observed_transaction_id, NULL::date AS observed_booking_date
 FROM manual_series s
 LEFT JOIN LATERAL finance.assign_bill_cycle(s.posting_date, s.account_id, s.closing_day, s.due_day) bill ON true
), lines AS MATERIALIZED (
 SELECT purchase_key, account_id, card_last4, payment_source_id, bill_group_id, merchant_name, description,
  purchase_anchor, installment_number, total_installments, installment_amount, purchase_total, installments_posted,
  posting_date, observed_posting_date, bill_closing_date, bill_due_date, bill_id, origin,
  observed_transaction_id, observed_booking_date
 FROM placed
 UNION ALL
 SELECT purchase_key, account_id, card_last4, payment_source_id, bill_group_id, merchant_name, description,
  purchase_anchor, installment_number, total_installments, installment_amount, purchase_total, installments_posted,
  posting_date, observed_posting_date, bill_closing_date, bill_due_date, bill_id, origin,
  observed_transaction_id, observed_booking_date
 FROM manual_placed
)
SELECT purchase_key, account_id, nullif(card_last4,'') card_last4, payment_source_id, bill_group_id,
 merchant_name, description, purchase_anchor purchase_date, installment_number, total_installments,
 installment_amount, purchase_total, installments_posted, (total_installments-installments_posted) installments_remaining,
 coalesce(observed_posting_date, posting_date) posting_date, bill_closing_date, bill_due_date, bill_id, origin,
 observed_transaction_id, observed_booking_date,
 max(coalesce(bill_due_date, observed_posting_date, posting_date)) OVER (PARTITION BY purchase_key) ends_on
FROM lines;


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
 (o.account_id IS NULL OR o.balance IS NULL) balance_missing
FROM opened o
JOIN future f ON f.source_id=o.source_id
JOIN processing p ON p.source_id=o.source_id;


CREATE VIEW finance.income_occurrences WITH (security_invoker=true) AS
WITH due AS MATERIALIZED (
 SELECT max(open_due_date) allowance_due_date FROM finance.current_invoice
), months AS MATERIALIZED (
 SELECT (date_trunc('month', finance.today_sp())+((n.n-2)*interval '1 month'))::date month_start
 FROM finance.number_series n WHERE n.n<=20
), plans AS MATERIALIZED (
 SELECT 'plan'::text source, e.id income_id, e.name, e.kind, e.periodicity, e.amount, e.estimated, m.month_start,
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
  e.signed_amount amount, false estimated, date_trunc('month', e.report_date)::date month_start, e.report_date credit_date
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
 ) in_vale,
 r.estimated
FROM rows r CROSS JOIN due d;


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
SELECT 'payment_source', ps.id, ps.slug, 'fechamento_estimado',
 'closing_day é estimativa (closing_day_estimated). Corrigir quando o fechamento real for informado.'
FROM finance.payment_sources ps
WHERE ps.active AND ps.closing_day_estimated
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
SELECT 'income', e.id, e.name, 'valor_estimado',
 'Valor marcado como estimativa. Ajustar amount e starts_on quando o crédito for confirmado.'
FROM finance.income_entries e
WHERE e.active AND e.estimated;


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
  max(open_due_date) allowance_due_date
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


ALTER TABLE finance.installment_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_all ON finance.installment_plans;

CREATE POLICY service_role_all ON finance.installment_plans FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS finance_reader_select ON finance.installment_plans;

CREATE POLICY finance_reader_select ON finance.installment_plans FOR SELECT TO finance_reader USING (true);


REVOKE ALL ON finance.installment_schedule, finance.current_invoice, finance.income_occurrences, finance.payment_source_review, finance.cashflow_month FROM PUBLIC, anon, authenticated;

REVOKE ALL ON finance.installment_plans FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION finance.last_business_day(date), finance.is_own_bank_transfer(uuid, text, text, numeric, date), finance.classify_pluggy(text, text, text, text, text, text, text), finance.apply_transaction_classification(), finance.reclassify_own_transfer_pairs(), finance.reclassify_own_transfer_pairs_after_statement() FROM PUBLIC, anon, authenticated;


DO $correction_grants$
DECLARE n text;
BEGIN
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
  GRANT SELECT, INSERT, UPDATE, DELETE ON finance.installment_plans TO service_role;
  GRANT SELECT ON finance.installment_schedule, finance.current_invoice, finance.income_occurrences, finance.payment_source_review, finance.cashflow_month TO service_role;
  GRANT EXECUTE ON FUNCTION finance.last_business_day(date), finance.is_own_bank_transfer(uuid, text, text, numeric, date), finance.classify_pluggy(text, text, text, text, text, text, text), finance.apply_transaction_classification(), finance.reclassify_own_transfer_pairs(), finance.reclassify_own_transfer_pairs_after_statement() TO service_role;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='dashboard_reader') THEN
  GRANT USAGE ON SCHEMA finance TO dashboard_reader;
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
  GRANT SELECT ON finance.installment_plans, finance.installment_schedule, finance.current_invoice, finance.income_occurrences, finance.payment_source_review, finance.cashflow_month TO finance_reader;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT USAGE ON SCHEMA finance TO supabase_read_only_user;
  GRANT SELECT ON finance.installment_plans, finance.installment_schedule, finance.current_invoice, finance.income_occurrences, finance.payment_source_review, finance.cashflow_month TO supabase_read_only_user;
  DROP POLICY IF EXISTS supabase_read_only_select ON finance.installment_plans;
  CREATE POLICY supabase_read_only_select ON finance.installment_plans FOR SELECT TO supabase_read_only_user USING (true);
 END IF;
END $correction_grants$;
