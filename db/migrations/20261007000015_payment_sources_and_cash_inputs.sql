CREATE TABLE IF NOT EXISTS finance.banks (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
 name text NOT NULL,
 slug text NOT NULL UNIQUE,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);


CREATE TABLE IF NOT EXISTS finance.payment_sources (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
 bank_id uuid NOT NULL REFERENCES finance.banks(id),
 slug text NOT NULL UNIQUE,
 kind text NOT NULL CHECK (kind IN ('credit','checking')),
 name text NOT NULL,
 parent_id uuid REFERENCES finance.payment_sources(id),
 closing_day smallint CHECK (closing_day BETWEEN 1 AND 31),
 closing_day_min smallint CHECK (closing_day_min BETWEEN 1 AND 31),
 due_day smallint CHECK (due_day BETWEEN 1 AND 31),
 card_last4 text CHECK (card_last4 IS NULL OR card_last4 ~ '^[0-9]{4}$'),
 account_id uuid REFERENCES finance.accounts(id) ON DELETE SET NULL,
 card_id uuid REFERENCES finance.cards(id) ON DELETE SET NULL,
 link_origin text CHECK (link_origin IS NULL OR link_origin IN ('auto','manual')),
 active boolean NOT NULL DEFAULT true,
 notes text,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (kind='credit' OR (closing_day IS NULL AND closing_day_min IS NULL AND due_day IS NULL AND parent_id IS NULL AND card_last4 IS NULL)),
 CHECK (parent_id IS NULL OR kind='credit'),
 CHECK (card_last4 IS NULL OR kind='credit'),
 CHECK (parent_id IS DISTINCT FROM id),
 CHECK (closing_day_min IS NULL OR closing_day IS NULL OR closing_day_min<=closing_day)
);


CREATE INDEX IF NOT EXISTS payment_sources_bank_idx ON finance.payment_sources(bank_id);

CREATE INDEX IF NOT EXISTS payment_sources_parent_idx ON finance.payment_sources(parent_id);

CREATE INDEX IF NOT EXISTS payment_sources_account_idx ON finance.payment_sources(account_id);

CREATE INDEX IF NOT EXISTS payment_sources_card_idx ON finance.payment_sources(card_id);

CREATE INDEX IF NOT EXISTS payment_sources_last4_idx ON finance.payment_sources(card_last4) WHERE card_last4 IS NOT NULL;


CREATE TABLE IF NOT EXISTS finance.income_entries (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
 name text NOT NULL UNIQUE,
 kind text NOT NULL CHECK (kind IN ('fixed','one_off')),
 amount numeric(14,2) NOT NULL CHECK (amount>=0),
 currency char(3) NOT NULL DEFAULT 'BRL' CHECK (currency='BRL'),
 day_of_month smallint CHECK (day_of_month BETWEEN 1 AND 31),
 periodicity text NOT NULL CHECK (periodicity IN ('monthly','yearly','once')),
 starts_on date NOT NULL,
 ends_on date,
 active boolean NOT NULL DEFAULT true,
 notes text,
 transaction_id uuid REFERENCES finance.transactions(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (ends_on IS NULL OR ends_on>=starts_on),
 CHECK ((kind='fixed' AND periodicity IN ('monthly','yearly')) OR (kind='one_off' AND periodicity='once'))
);


CREATE INDEX IF NOT EXISTS income_entries_tx_idx ON finance.income_entries(transaction_id);


CREATE TABLE IF NOT EXISTS finance.savings_goals (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
 name text NOT NULL UNIQUE,
 amount numeric(14,2) NOT NULL CHECK (amount>=0),
 currency char(3) NOT NULL DEFAULT 'BRL' CHECK (currency='BRL'),
 starts_on date NOT NULL,
 ends_on date,
 active boolean NOT NULL DEFAULT true,
 notes text,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (ends_on IS NULL OR ends_on>=starts_on)
);


ALTER TABLE finance.recurring_overrides ADD COLUMN IF NOT EXISTS periodicity text NOT NULL DEFAULT 'monthly';

ALTER TABLE finance.recurring_overrides ADD COLUMN IF NOT EXISTS payment_source_id uuid;

DO $recurring_constraints$
BEGIN
 ALTER TABLE finance.recurring_overrides ADD CONSTRAINT recurring_overrides_periodicity_chk CHECK (periodicity IN ('weekly','monthly','yearly'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $recurring_constraints$;

DO $recurring_source_fk$
BEGIN
 ALTER TABLE finance.recurring_overrides ADD CONSTRAINT recurring_overrides_payment_source_fkey FOREIGN KEY (payment_source_id) REFERENCES finance.payment_sources(id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $recurring_source_fk$;

CREATE INDEX IF NOT EXISTS recurring_overrides_account_idx ON finance.recurring_overrides(account_id);

CREATE INDEX IF NOT EXISTS recurring_overrides_source_idx ON finance.recurring_overrides(payment_source_id);


DROP TRIGGER IF EXISTS touch_updated_at ON finance.banks;

CREATE TRIGGER touch_updated_at BEFORE UPDATE ON finance.banks FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at();

DROP TRIGGER IF EXISTS touch_updated_at ON finance.payment_sources;

CREATE TRIGGER touch_updated_at BEFORE UPDATE ON finance.payment_sources FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at();

DROP TRIGGER IF EXISTS touch_updated_at ON finance.income_entries;

CREATE TRIGGER touch_updated_at BEFORE UPDATE ON finance.income_entries FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at();

DROP TRIGGER IF EXISTS touch_updated_at ON finance.savings_goals;

CREATE TRIGGER touch_updated_at BEFORE UPDATE ON finance.savings_goals FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at();



CREATE OR REPLACE FUNCTION finance.posting_closing_date(p_posting date, p_closing_day integer) RETURNS date
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog AS $$
 SELECT make_date(extract(year FROM shifted)::int, extract(month FROM shifted)::int, least(p_closing_day, last_day))
 FROM (
  SELECT CASE WHEN extract(day FROM p_posting)::int<=p_closing_day THEN date_trunc('month', p_posting)
              ELSE date_trunc('month', p_posting)+interval '1 month' END shifted
 ) s
 CROSS JOIN LATERAL (
  SELECT extract(day FROM (date_trunc('month', s.shifted)+interval '1 month - 1 day'))::int last_day
 ) d
$$;



CREATE OR REPLACE FUNCTION finance.open_closing_date(p_on date, p_closing_day integer) RETURNS date
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog AS $$
 SELECT make_date(extract(year FROM shifted)::int, extract(month FROM shifted)::int, least(p_closing_day, last_day))
 FROM (
  SELECT CASE WHEN extract(day FROM p_on)::int<p_closing_day THEN date_trunc('month', p_on)
              ELSE date_trunc('month', p_on)+interval '1 month' END shifted
 ) s
 CROSS JOIN LATERAL (
  SELECT extract(day FROM (date_trunc('month', s.shifted)+interval '1 month - 1 day'))::int last_day
 ) d
$$;



CREATE OR REPLACE FUNCTION finance.cycle_due_date(p_closing date, p_closing_day integer, p_due_day integer) RETURNS date
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog AS $$
 SELECT make_date(extract(year FROM shifted)::int, extract(month FROM shifted)::int, least(p_due_day, last_day))
 FROM (
  SELECT CASE WHEN p_due_day>p_closing_day THEN p_closing::timestamp ELSE p_closing::timestamp+interval '1 month' END shifted
 ) s
 CROSS JOIN LATERAL (
  SELECT extract(day FROM (date_trunc('month', s.shifted)+interval '1 month - 1 day'))::int last_day
 ) d
$$;


CREATE OR REPLACE FUNCTION finance.clamp_month_day(p_month date, p_day integer) RETURNS date
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path=pg_catalog AS $$
 SELECT make_date(extract(year FROM p_month)::int, extract(month FROM p_month)::int,
  least(p_day, extract(day FROM (date_trunc('month', p_month)+interval '1 month - 1 day'))::int))
$$;





CREATE OR REPLACE FUNCTION finance.assign_bill_cycle(p_posting date, p_account_id uuid, p_closing_day integer, p_due_day integer)
RETURNS TABLE(closing_date date, due_date date, bill_id uuid)
LANGUAGE sql STABLE SET search_path=pg_catalog,finance AS $$
 WITH nominal AS (
  SELECT finance.posting_closing_date(p_posting, p_closing_day) AS closing_date
 ), bills AS (
  SELECT b.id, b.closing_date, b.due_date,
   lag(b.closing_date) OVER (ORDER BY b.closing_date, b.id) prev_closing
  FROM finance.credit_card_bills b
  WHERE p_account_id IS NOT NULL AND b.account_id=p_account_id AND b.closing_date IS NOT NULL
 ), official AS (
  SELECT b.id, b.closing_date, b.due_date
  FROM bills b CROSS JOIN nominal n
  WHERE p_posting IS NOT NULL AND p_posting<=b.closing_date
   AND p_posting>coalesce(b.prev_closing, (b.closing_date-40))
   AND (b.prev_closing IS NOT NULL OR n.closing_date IS NULL OR abs(b.closing_date-n.closing_date)<=4)
  ORDER BY b.closing_date, b.id
  LIMIT 1
 )
 SELECT coalesce(o.closing_date, n.closing_date),
  coalesce(o.due_date, finance.cycle_due_date(n.closing_date, p_closing_day, p_due_day)),
  o.id
 FROM nominal n LEFT JOIN official o ON true
 WHERE coalesce(o.closing_date, n.closing_date) IS NOT NULL
$$;


CREATE OR REPLACE FUNCTION finance.open_bill_cycle(p_account_id uuid, p_closing_day integer, p_due_day integer, p_on date)
RETURNS TABLE(closing_date date, due_date date, bill_id uuid)
LANGUAGE sql STABLE SET search_path=pg_catalog,finance AS $$
 WITH nominal AS (
  SELECT finance.open_closing_date(p_on, p_closing_day) AS closing_date
 ), adjusted AS (
  SELECT CASE
   WHEN n.closing_date IS NOT NULL AND EXISTS (
    SELECT 1 FROM finance.credit_card_bills b
    WHERE b.account_id=p_account_id AND b.closing_date IS NOT NULL
     AND b.closing_date<=p_on AND abs(b.closing_date-n.closing_date)<=4
   ) THEN finance.open_closing_date((n.closing_date+1)::date, p_closing_day)
   ELSE n.closing_date END AS closing_date
  FROM nominal n
 ), official AS (
  SELECT b.id, b.closing_date, b.due_date
  FROM finance.credit_card_bills b CROSS JOIN adjusted a
  WHERE p_account_id IS NOT NULL AND b.account_id=p_account_id AND b.closing_date>p_on
   AND (a.closing_date IS NULL OR abs(b.closing_date-a.closing_date)<=4)
  ORDER BY b.closing_date, b.id
  LIMIT 1
 )
 SELECT coalesce(o.closing_date, a.closing_date),
  coalesce(o.due_date, finance.cycle_due_date(coalesce(o.closing_date, a.closing_date), p_closing_day, p_due_day)),
  o.id
 FROM adjusted a LEFT JOIN official o ON true
 WHERE coalesce(o.closing_date, a.closing_date) IS NOT NULL
$$;


CREATE OR REPLACE FUNCTION finance.link_payment_sources() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance AS $$
DECLARE n int:=0; r int;
BEGIN
 WITH matches AS (
  SELECT ps.id source_id, c.account_id, c.id card_id, count(*) OVER (PARTITION BY ps.id) n_match
  FROM finance.payment_sources ps
  JOIN finance.banks b ON b.id=ps.bank_id
  JOIN finance.cards c ON c.last4=ps.card_last4 AND c.active
  JOIN finance.accounts a ON a.id=c.account_id AND a.type='CREDIT' AND a.deleted_at IS NULL
  JOIN finance.items i ON i.id=a.item_id AND i.enabled AND lower(i.institution_slug)=b.slug
  WHERE ps.card_last4 IS NOT NULL AND ps.active AND coalesce(ps.link_origin,'auto')<>'manual'
 ), unique_match AS (
  SELECT source_id, account_id, card_id FROM matches WHERE n_match=1
 )
 UPDATE finance.payment_sources ps
 SET account_id=u.account_id, card_id=u.card_id, link_origin='auto'
 FROM unique_match u
 WHERE ps.id=u.source_id AND (ps.account_id IS DISTINCT FROM u.account_id OR ps.card_id IS DISTINCT FROM u.card_id OR ps.link_origin IS DISTINCT FROM 'auto');
 GET DIAGNOSTICS r=ROW_COUNT; n:=n+r;

 WITH matches AS (
  SELECT ps.id source_id, count(*) OVER (PARTITION BY ps.id) n_match
  FROM finance.payment_sources ps
  JOIN finance.banks b ON b.id=ps.bank_id
  JOIN finance.cards c ON c.last4=ps.card_last4 AND c.active
  JOIN finance.accounts a ON a.id=c.account_id AND a.type='CREDIT' AND a.deleted_at IS NULL
  JOIN finance.items i ON i.id=a.item_id AND i.enabled AND lower(i.institution_slug)=b.slug
  WHERE ps.card_last4 IS NOT NULL AND ps.active
 ), unique_ids AS (
  SELECT source_id FROM matches WHERE n_match=1
 )
 UPDATE finance.payment_sources ps
 SET account_id=NULL, card_id=NULL, link_origin=NULL
 WHERE ps.card_last4 IS NOT NULL AND ps.link_origin='auto' AND NOT EXISTS (SELECT 1 FROM unique_ids u WHERE u.source_id=ps.id);
 GET DIAGNOSTICS r=ROW_COUNT; n:=n+r;

 WITH child_acc AS (
  SELECT p.id parent_id, c.account_id
  FROM finance.payment_sources p
  JOIN finance.payment_sources c ON c.parent_id=p.id AND c.account_id IS NOT NULL
  WHERE p.kind='credit' AND p.parent_id IS NULL AND coalesce(p.link_origin,'auto')<>'manual'
  GROUP BY p.id, c.account_id
 ), agreed AS (
  SELECT parent_id, min(account_id::text)::uuid account_id FROM child_acc GROUP BY parent_id HAVING count(*)=1
 )
 UPDATE finance.payment_sources ps SET account_id=a.account_id, card_id=NULL, link_origin='auto'
 FROM agreed a
 WHERE ps.id=a.parent_id AND (ps.account_id IS DISTINCT FROM a.account_id OR ps.link_origin IS DISTINCT FROM 'auto');
 GET DIAGNOSTICS r=ROW_COUNT; n:=n+r;

 WITH child_acc AS (
  SELECT p.id parent_id, c.account_id
  FROM finance.payment_sources p
  JOIN finance.payment_sources c ON c.parent_id=p.id AND c.account_id IS NOT NULL
  WHERE p.kind='credit' AND p.parent_id IS NULL
  GROUP BY p.id, c.account_id
 ), agreed AS (
  SELECT parent_id FROM child_acc GROUP BY parent_id HAVING count(*)=1
 )
 UPDATE finance.payment_sources ps SET account_id=NULL, link_origin=NULL
 WHERE ps.kind='credit' AND ps.parent_id IS NULL AND ps.link_origin='auto'
  AND EXISTS (SELECT 1 FROM finance.payment_sources c WHERE c.parent_id=ps.id AND c.account_id IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM agreed a WHERE a.parent_id=ps.id);
 GET DIAGNOSTICS r=ROW_COUNT; n:=n+r;

 WITH matches AS (
  SELECT ps.id source_id, a.id account_id, count(*) OVER (PARTITION BY ps.id) n_match
  FROM finance.payment_sources ps
  JOIN finance.banks b ON b.id=ps.bank_id
  JOIN finance.items i ON i.enabled AND lower(i.institution_slug)=b.slug
  JOIN finance.accounts a ON a.item_id=i.id AND a.type='CREDIT' AND a.deleted_at IS NULL
  WHERE ps.kind='credit' AND ps.parent_id IS NULL AND ps.card_last4 IS NULL
   AND coalesce(ps.link_origin,'auto')<>'manual'
   AND NOT EXISTS (SELECT 1 FROM finance.payment_sources c WHERE c.parent_id=ps.id AND c.account_id IS NOT NULL)
 ), unique_match AS (
  SELECT source_id, account_id FROM matches WHERE n_match=1
 )
 UPDATE finance.payment_sources ps SET account_id=u.account_id, link_origin='auto'
 FROM unique_match u
 WHERE ps.id=u.source_id AND (ps.account_id IS DISTINCT FROM u.account_id OR ps.link_origin IS DISTINCT FROM 'auto');
 GET DIAGNOSTICS r=ROW_COUNT; n:=n+r;

 WITH matches AS (
  SELECT ps.id source_id, count(*) OVER (PARTITION BY ps.id) n_match
  FROM finance.payment_sources ps
  JOIN finance.banks b ON b.id=ps.bank_id
  JOIN finance.items i ON i.enabled AND lower(i.institution_slug)=b.slug
  JOIN finance.accounts a ON a.item_id=i.id AND a.type='CREDIT' AND a.deleted_at IS NULL
  WHERE ps.kind='credit' AND ps.parent_id IS NULL AND ps.card_last4 IS NULL
 )
 UPDATE finance.payment_sources ps SET account_id=NULL, link_origin=NULL
 WHERE ps.kind='credit' AND ps.parent_id IS NULL AND ps.card_last4 IS NULL AND ps.link_origin='auto'
  AND NOT EXISTS (SELECT 1 FROM finance.payment_sources c WHERE c.parent_id=ps.id AND c.account_id IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM matches m WHERE m.source_id=ps.id AND m.n_match=1);
 GET DIAGNOSTICS r=ROW_COUNT; n:=n+r;

 WITH matches AS (
  SELECT ps.id source_id, a.id account_id, count(*) OVER (PARTITION BY ps.id) n_match
  FROM finance.payment_sources ps
  JOIN finance.banks b ON b.id=ps.bank_id
  JOIN finance.items i ON i.enabled AND lower(i.institution_slug)=b.slug
  JOIN finance.accounts a ON a.item_id=i.id AND a.type='BANK' AND a.deleted_at IS NULL
   AND coalesce(a.subtype,'CHECKING_ACCOUNT')='CHECKING_ACCOUNT'
   AND a.name NOT ILIKE '%poup%'
  WHERE ps.kind='checking' AND ps.active AND coalesce(ps.link_origin,'auto')<>'manual'
 ), unique_match AS (
  SELECT source_id, account_id FROM matches WHERE n_match=1
 )
 UPDATE finance.payment_sources ps SET account_id=u.account_id, link_origin='auto'
 FROM unique_match u
 WHERE ps.id=u.source_id AND (ps.account_id IS DISTINCT FROM u.account_id OR ps.link_origin IS DISTINCT FROM 'auto');
 GET DIAGNOSTICS r=ROW_COUNT; n:=n+r;

 WITH matches AS (
  SELECT ps.id source_id, count(*) OVER (PARTITION BY ps.id) n_match
  FROM finance.payment_sources ps
  JOIN finance.banks b ON b.id=ps.bank_id
  JOIN finance.items i ON i.enabled AND lower(i.institution_slug)=b.slug
  JOIN finance.accounts a ON a.item_id=i.id AND a.type='BANK' AND a.deleted_at IS NULL
   AND coalesce(a.subtype,'CHECKING_ACCOUNT')='CHECKING_ACCOUNT'
   AND a.name NOT ILIKE '%poup%'
  WHERE ps.kind='checking' AND ps.active
 )
 UPDATE finance.payment_sources ps SET account_id=NULL, link_origin=NULL
 WHERE ps.kind='checking' AND ps.link_origin='auto'
  AND NOT EXISTS (SELECT 1 FROM matches m WHERE m.source_id=ps.id AND m.n_match=1);
 GET DIAGNOSTICS r=ROW_COUNT; n:=n+r;

 RETURN n;
END $$;


CREATE OR REPLACE FUNCTION finance.tg_link_payment_sources() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,finance AS $$
BEGIN
 PERFORM finance.link_payment_sources();
 RETURN NULL;
END $$;


DROP TRIGGER IF EXISTS payment_sources_link_accounts ON finance.accounts;

CREATE TRIGGER payment_sources_link_accounts
AFTER INSERT OR UPDATE OF item_id, type, subtype, name, deleted_at ON finance.accounts
FOR EACH STATEMENT EXECUTE FUNCTION finance.tg_link_payment_sources();

DROP TRIGGER IF EXISTS payment_sources_link_cards ON finance.cards;

CREATE TRIGGER payment_sources_link_cards
AFTER INSERT OR UPDATE OF account_id, last4, active ON finance.cards
FOR EACH STATEMENT EXECUTE FUNCTION finance.tg_link_payment_sources();


ALTER TABLE finance.banks ENABLE ROW LEVEL SECURITY;

ALTER TABLE finance.payment_sources ENABLE ROW LEVEL SECURITY;

ALTER TABLE finance.income_entries ENABLE ROW LEVEL SECURITY;

ALTER TABLE finance.savings_goals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_all ON finance.banks;

DROP POLICY IF EXISTS service_role_all ON finance.payment_sources;

DROP POLICY IF EXISTS service_role_all ON finance.income_entries;

DROP POLICY IF EXISTS service_role_all ON finance.savings_goals;

CREATE POLICY service_role_all ON finance.banks FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY service_role_all ON finance.payment_sources FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY service_role_all ON finance.income_entries FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY service_role_all ON finance.savings_goals FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS finance_reader_select ON finance.banks;

DROP POLICY IF EXISTS finance_reader_select ON finance.payment_sources;

DROP POLICY IF EXISTS finance_reader_select ON finance.income_entries;

DROP POLICY IF EXISTS finance_reader_select ON finance.savings_goals;

CREATE POLICY finance_reader_select ON finance.banks FOR SELECT TO finance_reader USING (true);

CREATE POLICY finance_reader_select ON finance.payment_sources FOR SELECT TO finance_reader USING (true);

CREATE POLICY finance_reader_select ON finance.income_entries FOR SELECT TO finance_reader USING (true);

CREATE POLICY finance_reader_select ON finance.savings_goals FOR SELECT TO finance_reader USING (true);


REVOKE ALL ON finance.banks, finance.payment_sources, finance.income_entries, finance.savings_goals FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION finance.posting_closing_date(date, integer), finance.open_closing_date(date, integer), finance.cycle_due_date(date, integer, integer), finance.clamp_month_day(date, integer), finance.assign_bill_cycle(date, uuid, integer, integer), finance.open_bill_cycle(uuid, integer, integer, date), finance.link_payment_sources(), finance.tg_link_payment_sources() FROM PUBLIC, anon, authenticated;


DO $cash_input_roles$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='dashboard_reader') THEN
  BEGIN
   CREATE ROLE dashboard_reader NOLOGIN;
  EXCEPTION WHEN duplicate_object THEN NULL; WHEN insufficient_privilege THEN
   RAISE NOTICE 'dashboard_reader deve ser criado por administrador';
  END;
 END IF;
END $cash_input_roles$;


DO $cash_input_grants$
BEGIN
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
  GRANT SELECT, INSERT, UPDATE, DELETE ON finance.banks, finance.payment_sources, finance.income_entries, finance.savings_goals TO service_role;
  GRANT EXECUTE ON FUNCTION finance.posting_closing_date(date, integer), finance.open_closing_date(date, integer), finance.cycle_due_date(date, integer, integer), finance.clamp_month_day(date, integer), finance.assign_bill_cycle(date, uuid, integer, integer), finance.open_bill_cycle(uuid, integer, integer, date), finance.link_payment_sources(), finance.tg_link_payment_sources() TO service_role;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='finance_reader') THEN
  GRANT SELECT ON finance.banks, finance.payment_sources, finance.income_entries, finance.savings_goals TO finance_reader;
  GRANT EXECUTE ON FUNCTION finance.posting_closing_date(date, integer), finance.open_closing_date(date, integer), finance.cycle_due_date(date, integer, integer), finance.clamp_month_day(date, integer), finance.assign_bill_cycle(date, uuid, integer, integer), finance.open_bill_cycle(uuid, integer, integer, date), finance.today_sp() TO finance_reader;
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_read_only_user') THEN
  GRANT USAGE ON SCHEMA finance TO supabase_read_only_user;
  GRANT SELECT ON finance.banks, finance.payment_sources, finance.income_entries, finance.savings_goals TO supabase_read_only_user;
  GRANT EXECUTE ON FUNCTION finance.posting_closing_date(date, integer), finance.open_closing_date(date, integer), finance.cycle_due_date(date, integer, integer), finance.clamp_month_day(date, integer), finance.assign_bill_cycle(date, uuid, integer, integer), finance.open_bill_cycle(uuid, integer, integer, date), finance.today_sp() TO supabase_read_only_user;
  DROP POLICY IF EXISTS supabase_read_only_select ON finance.banks;
  DROP POLICY IF EXISTS supabase_read_only_select ON finance.payment_sources;
  DROP POLICY IF EXISTS supabase_read_only_select ON finance.income_entries;
  DROP POLICY IF EXISTS supabase_read_only_select ON finance.savings_goals;
  CREATE POLICY supabase_read_only_select ON finance.banks FOR SELECT TO supabase_read_only_user USING (true);
  CREATE POLICY supabase_read_only_select ON finance.payment_sources FOR SELECT TO supabase_read_only_user USING (true);
  CREATE POLICY supabase_read_only_select ON finance.income_entries FOR SELECT TO supabase_read_only_user USING (true);
  CREATE POLICY supabase_read_only_select ON finance.savings_goals FOR SELECT TO supabase_read_only_user USING (true);
 END IF;
END $cash_input_grants$;
