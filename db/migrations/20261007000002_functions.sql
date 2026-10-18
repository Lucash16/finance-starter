CREATE OR REPLACE FUNCTION finance.normalize_merchant(p_value text) RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE SET search_path=pg_catalog,finance,extensions AS $$
 SELECT trim(regexp_replace(regexp_replace(lower(extensions.unaccent(coalesce(p_value,''))),
   '^(pag\s*\*|compra\s+|pix\s+|ted\s+|doc\s+|debito\s+|credito\s+|ifd\s*\*|mp\s*\*|pg\s*\*|ec\s*\*|\*\s*)+', '', 'g'), '[^a-z0-9]+', ' ', 'g'))
$$;


CREATE OR REPLACE FUNCTION finance.classify_transaction(p_account_type text, p_pluggy_type text, p_pluggy_category_id text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path=pg_catalog AS $$
 SELECT CASE
  WHEN p_account_type='CREDIT' AND p_pluggy_type='DEBIT' THEN 'expense'
  WHEN p_account_type='CREDIT' AND p_pluggy_type='CREDIT' AND p_pluggy_category_id='05100000' THEN 'card_payment'
  WHEN p_account_type='CREDIT' AND p_pluggy_type='CREDIT' THEN 'refund'
  WHEN p_account_type='BANK' AND p_pluggy_category_id='05100000' THEN 'card_payment'
  WHEN p_account_type='BANK' AND (p_pluggy_category_id LIKE '04%' OR p_pluggy_category_id='05060000') THEN 'internal_transfer'
  WHEN p_account_type='BANK' AND p_pluggy_category_id LIKE '03%' THEN 'investment'
  WHEN p_account_type='BANK' AND p_pluggy_type='DEBIT' THEN 'expense'
  WHEN p_account_type='BANK' AND p_pluggy_type='CREDIT' THEN 'income'
  ELSE 'unknown' END
$$;


CREATE OR REPLACE FUNCTION finance.touch_updated_at() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN NEW.updated_at=clock_timestamp(); RETURN NEW; END $$;

DO $$ DECLARE n text; BEGIN
 FOREACH n IN ARRAY ARRAY['items','accounts','cards','credit_card_bills','categories','category_mappings','merchants','budgets'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS touch_updated_at ON finance.%I',n);
  EXECUTE format('CREATE TRIGGER touch_updated_at BEFORE UPDATE ON finance.%I FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at()',n);
 END LOOP;
END $$;


CREATE OR REPLACE FUNCTION finance.validate_credit_account() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,finance AS $$
BEGIN IF NOT EXISTS(SELECT 1 FROM finance.accounts a WHERE a.id=NEW.account_id AND a.type='CREDIT') THEN RAISE EXCEPTION 'account must be CREDIT'; END IF; RETURN NEW; END $$;

DROP TRIGGER IF EXISTS cards_credit_account ON finance.cards;

CREATE TRIGGER cards_credit_account BEFORE INSERT OR UPDATE OF account_id ON finance.cards FOR EACH ROW EXECUTE FUNCTION finance.validate_credit_account();

DROP TRIGGER IF EXISTS bills_credit_account ON finance.credit_card_bills;

CREATE TRIGGER bills_credit_account BEFORE INSERT OR UPDATE OF account_id ON finance.credit_card_bills FOR EACH ROW EXECUTE FUNCTION finance.validate_credit_account();


CREATE OR REPLACE FUNCTION finance.audit_transaction_update() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,finance AS $$
DECLARE meaningful boolean; ctx text;
BEGIN
 meaningful := (to_jsonb(OLD)-ARRAY['last_seen_at','updated_at']) IS DISTINCT FROM (to_jsonb(NEW)-ARRAY['last_seen_at','updated_at']);
 IF meaningful THEN
  NEW.revision_no:=OLD.revision_no+1; NEW.updated_at:=clock_timestamp();
 END IF;
 RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS transaction_revision_before ON finance.transactions;

CREATE TRIGGER transaction_revision_before BEFORE UPDATE ON finance.transactions FOR EACH ROW EXECUTE FUNCTION finance.audit_transaction_update();


CREATE OR REPLACE FUNCTION finance.write_transaction_revision() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,finance AS $$
BEGIN
 IF TG_OP='INSERT' OR NEW.revision_no<>OLD.revision_no THEN
  INSERT INTO finance.transaction_revisions(transaction_id,revision_no,actor,reason,before_data,after_data,sync_run_id)
  VALUES(NEW.id,NEW.revision_no,coalesce(current_setting('finance.actor',true),'database'),current_setting('finance.reason',true),CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) END,to_jsonb(NEW),nullif(current_setting('finance.sync_run_id',true),'')::uuid);
 END IF; RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS transaction_revision_after ON finance.transactions;

CREATE TRIGGER transaction_revision_after AFTER INSERT OR UPDATE ON finance.transactions FOR EACH ROW EXECUTE FUNCTION finance.write_transaction_revision();


CREATE OR REPLACE FUNCTION finance.upsert_accounts(p_item_pluggy_id text,p_items jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance,extensions AS $$
DECLARE v_item uuid; x jsonb; n int:=0; v_type text; v_id text;
BEGIN
 SELECT id INTO v_item FROM finance.items WHERE pluggy_id=p_item_pluggy_id AND enabled;
 IF v_item IS NULL THEN RAISE EXCEPTION 'item not allowed'; END IF;
 FOR x IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  v_id:=x->>'id'; v_type:=upper(x->>'type');
  IF v_id IS NULL OR v_type NOT IN ('BANK','CREDIT') THEN CONTINUE; END IF;
  INSERT INTO finance.accounts(pluggy_id,item_id,type,subtype,name,number_masked,currency,balance,balance_observed_at,credit_limit,available_credit_limit,raw)
  VALUES(v_id,v_item,v_type,x->>'subtype',coalesce(x->>'name','Conta'),CASE WHEN x->>'number' IS NULL THEN NULL ELSE '****'||right(regexp_replace(x->>'number','\D','','g'),4) END,
   coalesce(x->>'currencyCode','BRL'),(x->>'balance')::numeric,now(),(x#>>'{creditData,creditLimit}')::numeric,(x#>>'{creditData,availableCreditLimit}')::numeric,x)
  ON CONFLICT(pluggy_id) DO UPDATE SET type=excluded.type,subtype=excluded.subtype,name=excluded.name,number_masked=excluded.number_masked,
   currency=excluded.currency,balance=excluded.balance,balance_observed_at=excluded.balance_observed_at,credit_limit=excluded.credit_limit,
   available_credit_limit=excluded.available_credit_limit,raw=excluded.raw,deleted_at=NULL WHERE finance.accounts.raw IS DISTINCT FROM excluded.raw;
  IF v_type='CREDIT' THEN
   INSERT INTO finance.cards(account_id,last4,brand,raw)
   SELECT a.id,right(regexp_replace(c.n,'\D','','g'),4),x#>>'{creditData,brand}',jsonb_build_object('number',c.n)
   FROM finance.accounts a CROSS JOIN LATERAL (
    SELECT x#>>'{creditCardMetadata,cardNumber}' n UNION ALL SELECT x#>>'{creditData,number}'
    UNION ALL SELECT z->>'number' FROM jsonb_array_elements(coalesce(x#>'{creditData,additionalCards}','[]')) z
   ) c WHERE a.pluggy_id=v_id AND c.n IS NOT NULL AND length(regexp_replace(c.n,'\D','','g'))>=4
   ON CONFLICT(account_id,last4) DO UPDATE SET active=true,brand=coalesce(excluded.brand,finance.cards.brand),raw=excluded.raw;
  END IF; n:=n+1;
 END LOOP; RETURN n;
END $$;


CREATE OR REPLACE FUNCTION finance.upsert_bills(p_account_pluggy_id text,p_items jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance,extensions AS $$
DECLARE v_account uuid; x jsonb; n int:=0;
BEGIN SELECT id INTO v_account FROM finance.accounts WHERE pluggy_id=p_account_pluggy_id AND type='CREDIT';
 IF v_account IS NULL THEN RAISE EXCEPTION 'credit account not found'; END IF;
 FOR x IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  INSERT INTO finance.credit_card_bills(pluggy_id,account_id,due_date,closing_date,total_amount,currency,minimum_payment_amount,allows_installments,finance_charges,payments,provider_created_at,provider_updated_at,raw)
  VALUES(x->>'id',v_account,left(x->>'dueDate',10)::date,nullif(left(x->>'billClosingDate',10),'')::date,(x->>'totalAmount')::numeric,
   coalesce(x->>'totalAmountCurrencyCode','BRL'),(x->>'minimumPaymentAmount')::numeric,(x->>'allowsInstallments')::boolean,
   coalesce(x->'financeCharges','[]'),coalesce(x->'payments','[]'),(x->>'createdAt')::timestamptz,(x->>'updatedAt')::timestamptz,x)
  ON CONFLICT(pluggy_id) DO UPDATE SET due_date=excluded.due_date,closing_date=excluded.closing_date,total_amount=excluded.total_amount,
   minimum_payment_amount=excluded.minimum_payment_amount,allows_installments=excluded.allows_installments,finance_charges=excluded.finance_charges,
   payments=excluded.payments,provider_updated_at=excluded.provider_updated_at,raw=excluded.raw WHERE finance.credit_card_bills.raw IS DISTINCT FROM excluded.raw;
  n:=n+1;
 END LOOP;
 UPDATE finance.transactions t SET bill_id=b.id FROM finance.credit_card_bills b WHERE t.account_id=v_account AND t.pluggy_bill_id=b.pluggy_id AND t.bill_id IS DISTINCT FROM b.id;
 RETURN n;
END $$;


CREATE OR REPLACE FUNCTION finance.upsert_pluggy_transactions(p_account_pluggy_id text,p_items jsonb,p_sync_run_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance,extensions AS $$
DECLARE a finance.accounts%ROWTYPE; x jsonb; v_amount numeric; v_signed numeric; v_currency text; v_norm text; v_desc text; v_l4 text; v_card uuid; v_bill uuid;
 v_hash text; v_provider_updated timestamptz; ins int:=0; upd int:=0; same int:=0; stale int:=0; review int:=0;
BEGIN
 SELECT * INTO a FROM finance.accounts WHERE pluggy_id=p_account_pluggy_id AND deleted_at IS NULL;
 IF a.id IS NULL THEN RAISE EXCEPTION 'account not found'; END IF;
 PERFORM set_config('finance.actor','pluggy-sync',true);
 PERFORM set_config('finance.sync_run_id',coalesce(p_sync_run_id::text,''),true);
 FOR x IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  IF x->>'id' IS NULL OR x->>'date' IS NULL THEN CONTINUE; END IF;
  
  IF EXISTS(SELECT 1 FROM finance.webhook_events w WHERE w.event='transactions/deleted'
    AND w.account_pluggy_id=p_account_pluggy_id AND coalesce(w.payload->'transactionIds','[]'::jsonb) ? (x->>'id'))
  THEN stale:=stale+1; CONTINUE; END IF;
  v_currency:=coalesce(x->>'currencyCode','BRL'); v_amount:=coalesce((x->>'amountInAccountCurrency')::numeric,(x->>'amount')::numeric);
  v_norm:=CASE WHEN v_currency='BRL' OR x->>'amountInAccountCurrency' IS NOT NULL THEN 'ready' ELSE 'needs_review' END;
  v_signed:=CASE WHEN v_norm='needs_review' THEN NULL WHEN a.type='CREDIT' THEN -v_amount ELSE v_amount END;
  v_desc:=coalesce(nullif(x->>'description',''),nullif(x->>'descriptionRaw',''),'Sem descrição');
  v_l4:=right(regexp_replace(coalesce(x#>>'{creditCardMetadata,cardNumber}',''),'\D','','g'),4); v_card:=NULL;
  IF a.type='CREDIT' AND length(v_l4)=4 THEN
   INSERT INTO finance.cards(account_id,last4,raw) VALUES(a.id,v_l4,jsonb_build_object('source','transaction','cardNumber',x#>>'{creditCardMetadata,cardNumber}'))
   ON CONFLICT(account_id,last4) DO UPDATE SET active=true
   RETURNING id INTO v_card;
  END IF;
  SELECT id INTO v_bill FROM finance.credit_card_bills WHERE account_id=a.id AND pluggy_id=x#>>'{creditCardMetadata,billId}';
  v_hash:=encode(extensions.digest(x::text,'sha256'),'hex'); v_provider_updated:=nullif(x->>'updatedAt','')::timestamptz;
  IF EXISTS(SELECT 1 FROM finance.transactions WHERE pluggy_id=x->>'id' AND provider_updated_at IS NOT NULL AND v_provider_updated IS NOT NULL AND provider_updated_at>v_provider_updated) THEN stale:=stale+1; CONTINUE; END IF;
  INSERT INTO finance.transactions(source,pluggy_id,account_id,card_id,bill_id,pluggy_bill_id,booking_date,purchase_date,occurred_at,description,description_raw,merchant_normalized,
   original_amount,original_currency,amount_in_account_currency,signed_amount,currency,normalization_status,pluggy_type,status,economic_type,pluggy_category_id,
   installment_number,total_installments,installment_total_amount,bill_forecast_month,bill_post_date,provider_created_at,provider_updated_at,raw,payload_hash)
  VALUES('pluggy',x->>'id',a.id,v_card,v_bill,x#>>'{creditCardMetadata,billId}',left(x->>'date',10)::date,nullif(left(x#>>'{creditCardMetadata,purchaseDate}',10),'')::date,
   nullif(x#>>'{creditCardMetadata,transactionDateTime}','')::timestamptz,v_desc,x->>'descriptionRaw',finance.normalize_merchant(coalesce(x#>>'{paymentData,receiver,name}',v_desc)),
   (x->>'amount')::numeric,v_currency,(x->>'amountInAccountCurrency')::numeric,v_signed,'BRL',v_norm,upper(x->>'type'),CASE WHEN upper(x->>'status')='PENDING' THEN 'pending' ELSE 'posted' END,
   finance.classify_transaction(a.type,upper(x->>'type'),x->>'categoryId'),x->>'categoryId',(x#>>'{creditCardMetadata,installmentNumber}')::int,
   (x#>>'{creditCardMetadata,totalInstallments}')::int,(x#>>'{creditCardMetadata,totalAmount}')::numeric,
   CASE WHEN x#>>'{creditCardMetadata,billForecastDate}' ~ '^\d{4}-\d{2}$' THEN ((x#>>'{creditCardMetadata,billForecastDate}')||'-01')::date END,
   nullif(left(x#>>'{creditCardMetadata,billPostDate}',10),'')::date,nullif(x->>'createdAt','')::timestamptz,v_provider_updated,x,v_hash)
  ON CONFLICT(pluggy_id) DO UPDATE SET account_id=excluded.account_id,card_id=excluded.card_id,bill_id=excluded.bill_id,pluggy_bill_id=excluded.pluggy_bill_id,
   booking_date=excluded.booking_date,purchase_date=excluded.purchase_date,occurred_at=excluded.occurred_at,description=excluded.description,description_raw=excluded.description_raw,
   merchant_normalized=excluded.merchant_normalized,original_amount=excluded.original_amount,original_currency=excluded.original_currency,
   amount_in_account_currency=excluded.amount_in_account_currency,signed_amount=excluded.signed_amount,currency=excluded.currency,normalization_status=excluded.normalization_status,
   pluggy_type=excluded.pluggy_type,status=excluded.status,economic_type=CASE WHEN finance.transactions.economic_type_override IS NULL THEN excluded.economic_type ELSE finance.transactions.economic_type END,
   pluggy_category_id=excluded.pluggy_category_id,installment_number=excluded.installment_number,total_installments=excluded.total_installments,
   installment_total_amount=excluded.installment_total_amount,bill_forecast_month=excluded.bill_forecast_month,bill_post_date=excluded.bill_post_date,
   provider_created_at=excluded.provider_created_at,provider_updated_at=excluded.provider_updated_at,raw=excluded.raw,payload_hash=excluded.payload_hash,last_seen_at=now(),deleted_at=NULL,deletion_reason=NULL
  WHERE finance.transactions.payload_hash IS DISTINCT FROM excluded.payload_hash OR finance.transactions.deleted_at IS NOT NULL;
  IF FOUND THEN IF EXISTS(SELECT 1 FROM finance.transactions WHERE pluggy_id=x->>'id' AND revision_no=1) THEN ins:=ins+1; ELSE upd:=upd+1; END IF; ELSE
   UPDATE finance.transactions SET last_seen_at=now() WHERE pluggy_id=x->>'id'; same:=same+1;
  END IF; IF v_norm='needs_review' THEN review:=review+1; END IF;
 END LOOP;
 RETURN jsonb_build_object('inserted',ins,'updated',upd,'unchanged',same,'stale',stale,'needs_review',review);
END $$;


CREATE OR REPLACE FUNCTION finance.soft_delete_pluggy_transactions(p_account_pluggy_id text,p_ids text[],p_reason text DEFAULT 'webhook_deleted') RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance AS $$
DECLARE n int; BEGIN PERFORM set_config('finance.actor','pluggy-sync',true);
 UPDATE finance.transactions t SET deleted_at=now(),deletion_reason=p_reason FROM finance.accounts a
 WHERE t.account_id=a.id AND a.pluggy_id=p_account_pluggy_id AND t.pluggy_id=ANY(p_ids) AND t.deleted_at IS NULL;
 GET DIAGNOSTICS n=ROW_COUNT;
 UPDATE finance.reconciliations r SET status='undone',ended_at=now() FROM finance.transactions t WHERE r.pluggy_tx_id=t.id AND t.pluggy_id=ANY(p_ids) AND r.status='active';
 RETURN n; END $$;

CREATE OR REPLACE FUNCTION finance.today_sp() RETURNS date
LANGUAGE sql STABLE PARALLEL SAFE
RETURN (now() AT TIME ZONE 'America/Sao_Paulo')::date;
