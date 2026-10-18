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
     .30*extensions.similarity(p.merchant_normalized,m.merchant_normalized))::numeric score,
    count(*) OVER() candidate_count
   FROM finance.transactions p LEFT JOIN finance.cards pc ON pc.id=p.card_id
   WHERE p.source='pluggy' AND p.deleted_at IS NULL AND p.normalization_status='ready'
    AND abs(p.signed_amount-m.signed_amount)<=.01
    AND abs(coalesce(p.purchase_date,p.booking_date)-m.report_date)<=3
    AND sign(p.signed_amount)=sign(m.signed_amount)
    AND (m.wanted_last4 IS NULL OR pc.last4=m.wanted_last4)
    AND (extensions.similarity(p.merchant_normalized,m.merchant_normalized)>=.35 OR
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
    SELECT (.45 + CASE WHEN abs(coalesce(p.purchase_date,p.booking_date)-m.report_date)=0 THEN .25 ELSE .15 END + .30*extensions.similarity(p.merchant_normalized,m.merchant_normalized)) score
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
 v_time timestamptz; v_desc text; v_hash text; old_hash text;
BEGIN
 IF p_request_id IS NULL OR length(p_request_id)<6 THEN RAISE EXCEPTION 'invalid request_id'; END IF;
 v_kind:=p_payload->>'kind'; IF v_kind NOT IN ('expense','income') THEN RAISE EXCEPTION 'kind must be expense or income'; END IF;
 BEGIN v_amount:=(p_payload->>'amount')::numeric; EXCEPTION WHEN others THEN RAISE EXCEPTION 'invalid amount'; END;
 IF v_amount<=0 OR v_amount>999999999999.99 THEN RAISE EXCEPTION 'amount out of range'; END IF;
 v_signed:=CASE WHEN v_kind='expense' THEN -v_amount ELSE v_amount END; v_desc:=trim(p_payload->>'description');
 IF coalesce(v_desc,'')='' THEN RAISE EXCEPTION 'description required'; END IF;
 IF nullif(p_payload->>'occurred_at','') IS NULL THEN v_time:=now();
 ELSIF p_payload->>'occurred_at' ~ '(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' THEN v_time:=(p_payload->>'occurred_at')::timestamptz;
 ELSE v_time:=(p_payload->>'occurred_at')::timestamp AT TIME ZONE 'America/Sao_Paulo'; END IF;
 IF p_payload->>'account' IS NOT NULL THEN SELECT id INTO v_account FROM finance.accounts WHERE pluggy_id=p_payload->>'account'; END IF;
 IF p_payload->>'card_last4' IS NOT NULL THEN
  SELECT c.id,c.account_id INTO v_card,v_card_account FROM finance.cards c WHERE c.last4=p_payload->>'card_last4' AND c.active
   AND (v_account IS NULL OR c.account_id=v_account) ORDER BY c.created_at LIMIT 1;
  IF v_card IS NOT NULL THEN v_account:=v_card_account; END IF;
 END IF;
 IF p_payload->>'category' IS NOT NULL THEN SELECT id INTO v_category FROM finance.categories WHERE slug=p_payload->>'category' OR id::text=p_payload->>'category'; END IF;
 v_hash:=encode(extensions.digest(p_payload::text,'sha256'),'hex'); SELECT payload_hash INTO old_hash FROM finance.transactions WHERE source='manual' AND source_key=p_request_id;
 IF old_hash IS NOT NULL AND old_hash<>v_hash THEN RAISE EXCEPTION 'request_id conflict'; END IF;
 INSERT INTO finance.transactions(source,source_key,account_id,card_id,booking_date,occurred_at,description,merchant_normalized,original_amount,original_currency,
  signed_amount,currency,normalization_status,status,economic_type,economic_type_override,user_category_id,raw,payload_hash)
 VALUES('manual',p_request_id,v_account,v_card,(v_time AT TIME ZONE 'America/Sao_Paulo')::date,v_time,v_desc,
  finance.normalize_merchant(coalesce(p_payload->>'merchant',v_desc)),v_amount,'BRL',v_signed,'BRL','ready','posted',v_kind,v_kind,v_category,
  p_payload||jsonb_build_object('verification_state','unverified'),v_hash)
 ON CONFLICT(source,source_key) WHERE source<>'pluggy' DO NOTHING RETURNING * INTO t;
 IF t.id IS NULL THEN SELECT * INTO t FROM finance.transactions WHERE source='manual' AND source_key=p_request_id; END IF;
 PERFORM finance.reconcile_pending(t.id);
 RETURN jsonb_build_object('transaction',to_jsonb(t),'reconciliations',coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM finance.reconciliations r WHERE r.manual_tx_id=t.id),'[]'::jsonb));
END $$;


CREATE OR REPLACE FUNCTION finance.confirm_reconciliation(p_id uuid) RETURNS finance.reconciliations
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance AS $$
DECLARE r finance.reconciliations; BEGIN
 SELECT * INTO r FROM finance.reconciliations WHERE id=p_id FOR UPDATE; IF r.id IS NULL THEN RAISE EXCEPTION 'reconciliation not found'; END IF;
 IF NOT EXISTS(SELECT 1 FROM finance.transactions WHERE id=r.manual_tx_id AND source='manual' AND deleted_at IS NULL) OR
    NOT EXISTS(SELECT 1 FROM finance.transactions WHERE id=r.pluggy_tx_id AND source='pluggy' AND deleted_at IS NULL) THEN RAISE EXCEPTION 'invalid reconciliation roles'; END IF;
 UPDATE finance.reconciliations SET status='active',method='user',ended_at=NULL WHERE id=p_id RETURNING * INTO r; RETURN r; END $$;

CREATE OR REPLACE FUNCTION finance.undo_reconciliation(p_id uuid) RETURNS finance.reconciliations
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance AS $$
DECLARE r finance.reconciliations; BEGIN UPDATE finance.reconciliations SET status='undone',ended_at=now() WHERE id=p_id AND status IN ('active','suggested') RETURNING * INTO r;
 IF r.id IS NULL THEN RAISE EXCEPTION 'active reconciliation not found'; END IF; RETURN r; END $$;
