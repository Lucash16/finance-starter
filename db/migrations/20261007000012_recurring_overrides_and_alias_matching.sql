CREATE OR REPLACE FUNCTION finance.merchant_key(p_normalized text) RETURNS uuid
LANGUAGE sql STABLE SET search_path=pg_catalog,finance AS $$
 SELECT ma.merchant_id
 FROM finance.merchant_aliases ma
 WHERE ma.normalized_alias ~ '^[a-z0-9 ]+$'
   AND coalesce(p_normalized,'') ~ ('(^| )'||ma.normalized_alias||'( |$)')
 ORDER BY length(ma.normalized_alias) DESC,ma.normalized_alias,ma.id
 LIMIT 1
$$;


CREATE OR REPLACE FUNCTION finance.merchant_match_score(a text,b text) RETURNS numeric
LANGUAGE sql STABLE SET search_path=pg_catalog,finance,extensions AS $$
 SELECT CASE
  WHEN finance.merchant_key(a) IS NOT NULL AND finance.merchant_key(a)=finance.merchant_key(b) THEN 1::numeric
  ELSE greatest(extensions.similarity(coalesce(a,''),coalesce(b,'')),
                extensions.word_similarity(coalesce(a,''),coalesce(b,'')),
                extensions.word_similarity(coalesce(b,''),coalesce(a,'')))::numeric
 END
$$;


CREATE OR REPLACE FUNCTION finance.reconcile_pending(p_manual_id uuid DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance,extensions AS $$
DECLARE m record; best record; second_score numeric; n int:=0; v_score numeric; v_status text;
BEGIN
 FOR m IN SELECT t.*,coalesce(c.last4,t.raw->>'card_last4') wanted_last4,
   coalesce(t.purchase_date,t.booking_date) report_date FROM finance.transactions t LEFT JOIN finance.cards c ON c.id=t.card_id
   WHERE t.source='manual' AND t.deleted_at IS NULL AND (p_manual_id IS NULL OR t.id=p_manual_id)
   AND NOT EXISTS(SELECT 1 FROM finance.reconciliations r WHERE r.manual_tx_id=t.id AND r.status='active')
   AND NOT EXISTS(SELECT 1 FROM finance.reconciliations r WHERE r.manual_tx_id=t.id AND r.status='suggested' AND r.ended_at IS NULL)
 LOOP
  SELECT q.* INTO best FROM (
   SELECT p.id,p.pluggy_id,
    (CASE WHEN abs(p.signed_amount-m.signed_amount)<=0.01 THEN .45 ELSE 0 END +
     CASE WHEN abs(coalesce(p.purchase_date,p.booking_date)-m.report_date)=0 THEN .25 ELSE .15 END +
     .30*finance.merchant_match_score(p.merchant_normalized,m.merchant_normalized))::numeric score,
    count(*) OVER() candidate_count
   FROM finance.transactions p LEFT JOIN finance.cards pc ON pc.id=p.card_id
   WHERE p.source='pluggy' AND p.deleted_at IS NULL AND p.normalization_status='ready'
    AND abs(p.signed_amount-m.signed_amount)<=.01
    AND abs(coalesce(p.purchase_date,p.booking_date)-m.report_date)<=3
    AND sign(p.signed_amount)=sign(m.signed_amount)
    AND (m.wanted_last4 IS NULL OR pc.last4=m.wanted_last4)
    AND (finance.merchant_match_score(p.merchant_normalized,m.merchant_normalized)>=.35 OR
      (coalesce(p.purchase_date,p.booking_date)=m.report_date AND NOT EXISTS(
       SELECT 1 FROM finance.transactions p2 WHERE p2.source='pluggy' AND p2.id<>p.id AND p2.deleted_at IS NULL
        AND abs(p2.signed_amount-m.signed_amount)<=.01 AND coalesce(p2.purchase_date,p2.booking_date)=m.report_date)))
    AND NOT EXISTS(SELECT 1 FROM finance.reconciliations r WHERE r.pluggy_tx_id=p.id AND r.status='active')
    AND NOT EXISTS(SELECT 1 FROM finance.reconciliations r WHERE r.manual_tx_id=m.id AND r.pluggy_tx_id=p.id)
    AND NOT (coalesce(p.total_installments,1)>1 AND (m.raw->>'is_total_purchase')::boolean IS TRUE)
   ORDER BY score DESC
  ) q ORDER BY q.score DESC LIMIT 1;
  IF best.id IS NOT NULL THEN
   SELECT max(score) INTO second_score FROM (
    SELECT (.45 + CASE WHEN abs(coalesce(p.purchase_date,p.booking_date)-m.report_date)=0 THEN .25 ELSE .15 END + .30*finance.merchant_match_score(p.merchant_normalized,m.merchant_normalized)) score
    FROM finance.transactions p WHERE p.source='pluggy' AND p.id<>best.id AND p.deleted_at IS NULL
     AND abs(p.signed_amount-m.signed_amount)<=.01 AND abs(coalesce(p.purchase_date,p.booking_date)-m.report_date)<=3) s;
   v_status:=CASE WHEN second_score IS NULL OR best.score-second_score>.15 THEN 'active' ELSE 'suggested' END;
   INSERT INTO finance.reconciliations(manual_tx_id,pluggy_tx_id,status,score,method,evidence)
   VALUES(m.id,best.id,v_status,least(best.score,1),'auto',jsonb_build_object('rule','amount_date_merchant_v1'))
   ON CONFLICT DO NOTHING; n:=n+1;
  END IF;
 END LOOP; RETURN n;
END $$;


CREATE OR REPLACE FUNCTION finance.create_manual_entry(p_request_id text,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance,extensions AS $$
DECLARE t finance.transactions%ROWTYPE; v_kind text; v_amount numeric; v_signed numeric; v_account uuid; v_card uuid; v_card_account uuid; v_category uuid;
 v_time timestamptz; v_desc text; v_hash text; old_hash text; v_date text; v_reconciliation text; v_balance numeric;
BEGIN
 IF p_request_id IS NULL OR length(p_request_id)<6 THEN RAISE EXCEPTION 'invalid request_id'; END IF;
 v_kind:=coalesce(nullif(p_payload->>'kind',''),'expense'); IF v_kind NOT IN ('expense','income') THEN RAISE EXCEPTION 'kind must be expense or income'; END IF;
 BEGIN
  IF jsonb_typeof(p_payload->'amount')='number' THEN v_amount:=(p_payload->>'amount')::numeric;
  ELSE v_amount:=replace(replace(regexp_replace(p_payload->>'amount','[[:space:]R$]','','g'),'.',''),',','.')::numeric; END IF;
 EXCEPTION WHEN others THEN RAISE EXCEPTION 'invalid amount'; END;
 IF v_amount<=0 OR v_amount>999999999999.99 THEN RAISE EXCEPTION 'amount out of range'; END IF;
 v_signed:=CASE WHEN v_kind='expense' THEN -v_amount ELSE v_amount END; v_desc:=trim(p_payload->>'description');
 IF coalesce(v_desc,'')='' THEN RAISE EXCEPTION 'description required'; END IF;
 v_date:=coalesce(nullif(p_payload->>'date',''),nullif(p_payload->>'occurred_at',''));
 IF v_date IS NULL THEN v_time:=now(); ELSIF v_date ~ '^\d{4}-\d{2}-\d{2}$' THEN v_time:=v_date::date::timestamp AT TIME ZONE 'America/Sao_Paulo';
 ELSIF v_date ~ '(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' THEN v_time:=v_date::timestamptz; ELSE v_time:=v_date::timestamp AT TIME ZONE 'America/Sao_Paulo'; END IF;
 IF p_payload->>'account' IS NOT NULL THEN
  SELECT a.id INTO v_account FROM finance.accounts a JOIN finance.items i ON i.id=a.item_id
  WHERE a.pluggy_id=p_payload->>'account' OR lower(i.institution_slug)||CASE WHEN a.type='CREDIT' THEN '-cartao' ELSE '' END=lower(p_payload->>'account')
  ORDER BY a.updated_at DESC LIMIT 1;
  IF v_account IS NULL THEN RAISE EXCEPTION 'account not found'; END IF;
 END IF;
 IF p_payload->>'card_last4' IS NOT NULL THEN
  SELECT c.id,c.account_id INTO v_card,v_card_account FROM finance.cards c WHERE c.last4=p_payload->>'card_last4' AND c.active AND (v_account IS NULL OR c.account_id=v_account) ORDER BY c.created_at LIMIT 1;
  IF v_card IS NOT NULL THEN v_account:=v_card_account; END IF;
 END IF;
 IF p_payload->>'category' IS NOT NULL THEN
  SELECT id INTO v_category FROM finance.categories WHERE slug=finance.normalize_merchant(p_payload->>'category') OR finance.normalize_merchant(name)=finance.normalize_merchant(p_payload->>'category') OR id::text=p_payload->>'category';
  IF v_category IS NULL THEN RAISE EXCEPTION 'category not found'; END IF;
 END IF;
 v_hash:=encode(extensions.digest(p_payload::text,'sha256'),'hex'); SELECT payload_hash INTO old_hash FROM finance.transactions WHERE source='manual' AND source_key=p_request_id;
 IF old_hash IS NOT NULL AND old_hash<>v_hash THEN RAISE EXCEPTION 'request_id conflict'; END IF;
 INSERT INTO finance.transactions(source,source_key,account_id,card_id,booking_date,occurred_at,description,merchant_normalized,original_amount,original_currency,signed_amount,currency,normalization_status,status,economic_type,economic_type_override,user_category_id,raw,payload_hash,classification_reason)
 VALUES('manual',p_request_id,v_account,v_card,(v_time AT TIME ZONE 'America/Sao_Paulo')::date,v_time,v_desc,finance.normalize_merchant(coalesce(nullif(p_payload->>'merchant',''),v_desc)),v_amount,'BRL',v_signed,'BRL','ready','posted',v_kind,v_kind,v_category,p_payload||jsonb_build_object('verification_state','unverified'),v_hash,'manual_entry')
 ON CONFLICT(source,source_key) WHERE source<>'pluggy' DO NOTHING RETURNING * INTO t;
 IF t.id IS NULL THEN SELECT * INTO t FROM finance.transactions WHERE source='manual' AND source_key=p_request_id; END IF;
 PERFORM finance.reconcile_pending(t.id);
 SELECT coalesce((SELECT status FROM finance.reconciliations WHERE manual_tx_id=t.id AND status IN ('active','suggested') ORDER BY created_at DESC LIMIT 1),'unmatched') INTO v_reconciliation;
 SELECT available_balance INTO v_balance FROM finance.budget_status ORDER BY start_date DESC LIMIT 1;
 RETURN jsonb_build_object('id',t.id,'reconciliation_status',v_reconciliation,'available_balance',v_balance,
  'transaction',to_jsonb(t),'reconciliations',coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM finance.reconciliations r WHERE r.manual_tx_id=t.id),'[]'::jsonb));
END $$;


CREATE TABLE IF NOT EXISTS finance.recurring_overrides (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
 label text NOT NULL UNIQUE,
 merchant_pattern text NOT NULL,
 account_id uuid REFERENCES finance.accounts(id),
 card_last4 text,
 status text NOT NULL CHECK(status IN ('active','cancel_requested','cancelled','ending')),
 expected_amount numeric(14,2),
 currency text NOT NULL DEFAULT 'BRL',
 expected_day int CHECK(expected_day BETWEEN 1 AND 31),
 effective_date date,
 end_date date,
 notes text,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(status<>'ending' OR end_date IS NOT NULL)
);


DROP TRIGGER IF EXISTS touch_updated_at ON finance.recurring_overrides;

CREATE TRIGGER touch_updated_at BEFORE UPDATE ON finance.recurring_overrides FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at();


ALTER TABLE finance.recurring_overrides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_all ON finance.recurring_overrides;

CREATE POLICY service_role_all ON finance.recurring_overrides FOR ALL TO service_role USING(true) WITH CHECK(true);

DROP POLICY IF EXISTS finance_reader_select ON finance.recurring_overrides;

CREATE POLICY finance_reader_select ON finance.recurring_overrides FOR SELECT TO finance_reader USING(true);


DROP VIEW IF EXISTS finance.recurring_subscriptions;

CREATE VIEW finance.recurring_subscriptions WITH (security_invoker=true) AS
WITH x AS (
 SELECT account_id,card_last4,merchant_name,merchant_normalized,report_date,expense_amount,
  lag(report_date) OVER(PARTITION BY account_id,card_last4,merchant_normalized ORDER BY report_date) prev_date
 FROM finance.transactions_enriched
 WHERE is_effective AND status='posted' AND counts_as_expense AND coalesce(total_installments,1)=1
), g AS (
 SELECT account_id,card_last4,max(merchant_name) merchant_name,merchant_normalized,count(*) occurrences,
  min(expense_amount) min_amount,max(expense_amount) max_amount,max(report_date) last_occurrence,
  avg(report_date-prev_date) FILTER(WHERE prev_date IS NOT NULL) average_interval_days
 FROM x GROUP BY account_id,card_last4,merchant_normalized
), detected AS (
 SELECT * FROM g WHERE occurrences>=3 AND average_interval_days BETWEEN 25 AND 35
  AND (max_amount-min_amount)<=greatest(max_amount*.10,.01)
), detected_with_override AS (
 SELECT d.*,o.id override_id,o.label override_label,o.status override_status,o.end_date,o.expected_amount,o.expected_day
 FROM detected d
 LEFT JOIN LATERAL (
  SELECT ro.* FROM finance.recurring_overrides ro
  WHERE d.merchant_normalized ~ ro.merchant_pattern
   AND (ro.account_id IS NULL OR ro.account_id=d.account_id)
   AND (ro.card_last4 IS NULL OR ro.card_last4=d.card_last4)
  ORDER BY ((ro.account_id IS NOT NULL)::int+(ro.card_last4 IS NOT NULL)::int) DESC,
           length(ro.merchant_pattern) DESC,ro.id
  LIMIT 1
 ) o ON true
), detected_dates AS (
 SELECT d.*,
  CASE WHEN d.expected_day IS NULL THEN d.last_occurrence+round(d.average_interval_days)::int
       ELSE nd.next_date END raw_next_date
 FROM detected_with_override d
 LEFT JOIN LATERAL (
  SELECT CASE WHEN cur_date>d.last_occurrence THEN cur_date ELSE next_date END next_date
  FROM LATERAL (SELECT make_date(extract(year FROM d.last_occurrence)::int,extract(month FROM d.last_occurrence)::int,
    least(d.expected_day,extract(day FROM (date_trunc('month',d.last_occurrence)+interval '1 month - 1 day'))::int)) cur_date) c
  CROSS JOIN LATERAL (SELECT make_date(extract(year FROM (d.last_occurrence+interval '1 month'))::int,extract(month FROM (d.last_occurrence+interval '1 month'))::int,
    least(d.expected_day,extract(day FROM (date_trunc('month',d.last_occurrence)+interval '2 months - 1 day'))::int)) next_date) n
 ) nd ON d.expected_day IS NOT NULL
), override_stats AS (
 SELECT o.*,s.occurrences,s.min_amount,s.max_amount,l.account_id last_account_id,l.card_last4 last_card_last4,
  l.report_date last_occurrence
 FROM finance.recurring_overrides o
 LEFT JOIN LATERAL (
  SELECT count(*)::bigint occurrences,min(e.expense_amount) min_amount,max(e.expense_amount) max_amount
  FROM finance.transactions_enriched e
  WHERE e.is_effective AND e.status='posted' AND e.counts_as_expense AND coalesce(e.total_installments,1)=1
   AND e.report_date>=finance.today_sp()-120 AND e.merchant_normalized ~ o.merchant_pattern
   AND (o.account_id IS NULL OR o.account_id=e.account_id) AND (o.card_last4 IS NULL OR o.card_last4=e.card_last4)
   AND (o.expected_amount IS NULL OR abs(e.expense_amount-o.expected_amount)<=abs(o.expected_amount)*.15)
 ) s ON true
 LEFT JOIN LATERAL (
  SELECT e.account_id,e.card_last4,e.report_date
  FROM finance.transactions_enriched e
  WHERE e.is_effective AND e.status='posted' AND e.counts_as_expense AND coalesce(e.total_installments,1)=1
   AND e.merchant_normalized ~ o.merchant_pattern
   AND (o.account_id IS NULL OR o.account_id=e.account_id) AND (o.card_last4 IS NULL OR o.card_last4=e.card_last4)
   AND (o.expected_amount IS NULL OR abs(e.expense_amount-o.expected_amount)<=abs(o.expected_amount)*.15)
  ORDER BY e.report_date DESC,e.id DESC LIMIT 1
 ) l ON true
 WHERE o.status IN ('active','ending','cancel_requested')
  AND NOT EXISTS(SELECT 1 FROM detected d WHERE d.merchant_normalized ~ o.merchant_pattern
   AND (o.account_id IS NULL OR o.account_id=d.account_id) AND (o.card_last4 IS NULL OR o.card_last4=d.card_last4))
), override_dates AS (
 SELECT o.*,greatest(coalesce(o.last_occurrence,o.effective_date,finance.today_sp()-1),finance.today_sp()-1) anchor_date
 FROM override_stats o
), override_next AS (
 SELECT o.*,nd.next_date raw_next_date
 FROM override_dates o
 LEFT JOIN LATERAL (
  SELECT CASE WHEN cur_date>o.anchor_date THEN cur_date ELSE next_date END next_date
  FROM LATERAL (SELECT make_date(extract(year FROM o.anchor_date)::int,extract(month FROM o.anchor_date)::int,
    least(o.expected_day,extract(day FROM (date_trunc('month',o.anchor_date)+interval '1 month - 1 day'))::int)) cur_date) c
  CROSS JOIN LATERAL (SELECT make_date(extract(year FROM (o.anchor_date+interval '1 month'))::int,extract(month FROM (o.anchor_date+interval '1 month'))::int,
    least(o.expected_day,extract(day FROM (date_trunc('month',o.anchor_date)+interval '2 months - 1 day'))::int)) next_date) n
 ) nd ON o.expected_day IS NOT NULL
)
SELECT d.account_id,d.card_last4,d.merchant_name,d.occurrences,d.min_amount,d.max_amount,d.last_occurrence,d.average_interval_days,
 CASE WHEN d.override_status='cancelled' OR (d.override_status='ending' AND d.raw_next_date>d.end_date) THEN NULL ELSE d.raw_next_date END estimated_next_date,
 'detected'::text source,d.override_id,d.override_label,d.override_status,d.end_date,d.expected_amount,
 (CASE WHEN d.override_status='cancelled' OR (d.override_status='ending' AND d.raw_next_date>d.end_date) THEN NULL ELSE d.raw_next_date END IS NOT NULL) is_expected
FROM detected_dates d
UNION ALL
SELECT coalesce(o.account_id,o.last_account_id),coalesce(o.card_last4,o.last_card_last4),o.label,o.occurrences,o.min_amount,o.max_amount,o.last_occurrence,
 NULL::numeric average_interval_days,
 CASE WHEN o.status='ending' AND o.raw_next_date>o.end_date THEN NULL ELSE o.raw_next_date END estimated_next_date,
 'override'::text source,o.id,o.label,o.status,o.end_date,o.expected_amount,
 (CASE WHEN o.status='ending' AND o.raw_next_date>o.end_date THEN NULL ELSE o.raw_next_date END IS NOT NULL) is_expected
FROM override_next o;


DO $recurring_grants$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
  GRANT SELECT,INSERT,UPDATE,DELETE ON finance.recurring_overrides TO service_role;
  GRANT SELECT ON finance.recurring_subscriptions TO service_role;
  GRANT EXECUTE ON FUNCTION finance.merchant_key(text),finance.merchant_match_score(text,text) TO service_role;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN
  GRANT SELECT ON finance.recurring_overrides,finance.recurring_subscriptions TO finance_reader;
  GRANT EXECUTE ON FUNCTION finance.merchant_key(text),finance.merchant_match_score(text,text) TO finance_reader;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT SELECT ON finance.recurring_overrides,finance.recurring_subscriptions TO supabase_read_only_user;
  GRANT EXECUTE ON FUNCTION finance.merchant_key(text),finance.merchant_match_score(text,text) TO supabase_read_only_user;
  DROP POLICY IF EXISTS supabase_read_only_select ON finance.recurring_overrides;
  CREATE POLICY supabase_read_only_select ON finance.recurring_overrides FOR SELECT TO supabase_read_only_user USING(true);
 END IF;
END $recurring_grants$;


DROP EVENT TRIGGER IF EXISTS finance_recurring_view_replay;

DROP FUNCTION IF EXISTS finance.allow_historical_recurring_view_replay();
