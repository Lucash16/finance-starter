CREATE TABLE IF NOT EXISTS finance.owner_identities (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
 kind text NOT NULL CHECK(kind IN ('document','name')),
 value_normalized text NOT NULL,
 source text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(kind,value_normalized)
);

CREATE TABLE IF NOT EXISTS finance.classification_rules (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), priority integer NOT NULL,
 account_type text CHECK(account_type IN ('BANK','CREDIT')), description_regex text, payee_regex text,
 economic_type text NOT NULL CHECK(economic_type IN ('expense','income','refund','internal_transfer','card_payment','investment','unknown')),
 category_slug text REFERENCES finance.categories(slug), reason text NOT NULL, active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(reason)
);

ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS classification_reason text;

ALTER TABLE finance.transactions ADD COLUMN IF NOT EXISTS classification_override_note text;


CREATE OR REPLACE FUNCTION finance.capture_owner_identities() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,finance AS $$
DECLARE v text;
BEGIN
 v:=regexp_replace(coalesce(NEW.raw->>'taxNumber',''),'\D','','g');
 IF v<>'' THEN INSERT INTO finance.owner_identities(kind,value_normalized,source) VALUES('document',v,'pluggy_account') ON CONFLICT(kind,value_normalized) DO UPDATE SET updated_at=now(); END IF;
 v:=finance.normalize_merchant(NEW.raw->>'owner');
 IF v<>'' THEN INSERT INTO finance.owner_identities(kind,value_normalized,source) VALUES('name',v,'pluggy_account') ON CONFLICT(kind,value_normalized) DO UPDATE SET updated_at=now(); END IF;
 RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS accounts_owner_identities ON finance.accounts;

CREATE TRIGGER accounts_owner_identities AFTER INSERT OR UPDATE OF raw ON finance.accounts FOR EACH ROW EXECUTE FUNCTION finance.capture_owner_identities();


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
 END IF;
 IF p_account_type='CREDIT' AND p_pluggy_type='DEBIT' AND v_desc ~ '^pix[[:space:]]+' THEN
  v_person:=finance.normalize_merchant(regexp_replace(v_desc,'^pix[[:space:]]+','',''));
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
 NEW.economic_type:=c.economic_type; NEW.classification_reason:=c.reason;
 base_economic_type:=finance.classify_transaction(a_type,NEW.pluggy_type,NEW.pluggy_category_id);
 IF c.category_slug IS NOT NULL AND (NEW.pluggy_category_id IS NULL OR c.economic_type IS DISTINCT FROM base_economic_type) THEN
  SELECT id INTO NEW.user_category_id FROM finance.categories WHERE slug=c.category_slug;
 END IF;
 RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS transaction_classification ON finance.transactions;

CREATE TRIGGER transaction_classification BEFORE INSERT OR UPDATE OF raw,description,pluggy_type,pluggy_category_id,economic_type_override ON finance.transactions FOR EACH ROW EXECUTE FUNCTION finance.apply_transaction_classification();


CREATE OR REPLACE FUNCTION finance.set_transaction_classification(p_tx uuid,p_economic_type text,p_category_slug text,p_note text) RETURNS finance.transactions
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance AS $$
DECLARE t finance.transactions;
BEGIN
 IF p_economic_type NOT IN ('expense','income','refund','internal_transfer','card_payment','investment','unknown') THEN RAISE EXCEPTION 'invalid economic_type'; END IF;
 PERFORM set_config('finance.actor','classification-override',true); PERFORM set_config('finance.reason',coalesce(p_note,'user override'),true);
 UPDATE finance.transactions SET economic_type_override=p_economic_type,economic_type=p_economic_type,
  user_category_id=(SELECT id FROM finance.categories WHERE slug=p_category_slug),classification_reason='user_override',classification_override_note=p_note
 WHERE id=p_tx RETURNING * INTO t;
 IF t.id IS NULL THEN RAISE EXCEPTION 'transaction not found'; END IF; RETURN t;
END $$;

CREATE OR REPLACE FUNCTION finance.reapply_classification() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance AS $$
DECLARE n integer;
BEGIN
 UPDATE finance.transactions SET raw=raw WHERE source='pluggy' AND economic_type_override IS NULL AND deleted_at IS NULL;
 GET DIAGNOSTICS n=ROW_COUNT; RETURN n;
END $$;


CREATE OR REPLACE VIEW finance.classification_review WITH (security_invoker=true) AS
SELECT t.id,t.booking_date,t.description,t.signed_amount,t.economic_type,t.classification_reason,
 CASE WHEN t.normalization_status='needs_review' THEN 'normalization' ELSE 'possible_nubank_bill_payment' END review_type,
 CASE WHEN t.normalization_status='needs_review' THEN 'Moeda sem conversão BRL' ELSE 'Valor e data próximos de fatura Nubank' END suggestion
FROM finance.transactions t LEFT JOIN finance.accounts a ON a.id=t.account_id
WHERE t.deleted_at IS NULL AND (t.normalization_status='needs_review' OR
 (a.type='CREDIT' AND t.pluggy_type='DEBIT' AND lower(extensions.unaccent(t.description)) ~ '^pix[[:space:]]+'
  AND t.economic_type='expense' AND EXISTS(SELECT 1 FROM finance.credit_card_bills b JOIN finance.accounts ba ON ba.id=b.account_id JOIN finance.items i ON i.id=ba.item_id
   WHERE i.institution_slug='nubank' AND abs(abs(t.signed_amount)-abs(b.total_amount))<=.01 AND abs(t.booking_date-b.due_date)<=10)));


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
 VALUES('manual',p_request_id,v_account,v_card,(v_time AT TIME ZONE 'America/Sao_Paulo')::date,v_time,v_desc,finance.normalize_merchant(v_desc),v_amount,'BRL',v_signed,'BRL','ready','posted',v_kind,v_kind,v_category,p_payload||jsonb_build_object('verification_state','unverified'),v_hash,'manual_entry')
 ON CONFLICT(source,source_key) WHERE source<>'pluggy' DO NOTHING RETURNING * INTO t;
 IF t.id IS NULL THEN SELECT * INTO t FROM finance.transactions WHERE source='manual' AND source_key=p_request_id; END IF;
 PERFORM finance.reconcile_pending(t.id);
 SELECT coalesce((SELECT status FROM finance.reconciliations WHERE manual_tx_id=t.id AND status IN ('active','suggested') ORDER BY created_at DESC LIMIT 1),'unmatched') INTO v_reconciliation;
 SELECT available_balance INTO v_balance FROM finance.budget_status ORDER BY start_date DESC LIMIT 1;
 RETURN jsonb_build_object('id',t.id,'reconciliation_status',v_reconciliation,'available_balance',v_balance,
  'transaction',to_jsonb(t),'reconciliations',coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM finance.reconciliations r WHERE r.manual_tx_id=t.id),'[]'::jsonb));
END $$;


DO $$ DECLARE n text; BEGIN
 FOREACH n IN ARRAY ARRAY['owner_identities','classification_rules'] LOOP
  EXECUTE format('ALTER TABLE finance.%I ENABLE ROW LEVEL SECURITY',n);
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
   EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON finance.%I TO service_role',n);
   EXECUTE format('DROP POLICY IF EXISTS service_role_all ON finance.%I',n);
   EXECUTE format('CREATE POLICY service_role_all ON finance.%I FOR ALL TO service_role USING(true) WITH CHECK(true)',n);
  END IF;
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN
   EXECUTE format('GRANT SELECT ON finance.%I TO finance_reader',n);
   EXECUTE format('DROP POLICY IF EXISTS finance_reader_select ON finance.%I',n);
   EXECUTE format('CREATE POLICY finance_reader_select ON finance.%I FOR SELECT TO finance_reader USING(true)',n);
  END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN GRANT SELECT ON finance.classification_review TO service_role; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN GRANT SELECT ON finance.classification_review TO finance_reader; END IF;
 GRANT EXECUTE ON FUNCTION finance.set_transaction_classification(uuid,text,text,text),finance.reapply_classification() TO service_role;
END $$;
