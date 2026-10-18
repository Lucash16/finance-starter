CREATE SCHEMA IF NOT EXISTS extensions;

CREATE SCHEMA IF NOT EXISTS finance;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;


CREATE TABLE IF NOT EXISTS finance.items (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), pluggy_id text NOT NULL UNIQUE,
 institution_name text NOT NULL, institution_slug text NOT NULL, connector_id integer,
 enabled boolean NOT NULL DEFAULT true, status text, execution_status text,
 last_updated_at timestamptz, next_auto_sync_at timestamptz, consent_expires_at timestamptz,
 error jsonb, status_detail jsonb, raw jsonb NOT NULL DEFAULT '{}'::jsonb,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (jsonb_typeof(raw)='object')
);

CREATE TABLE IF NOT EXISTS finance.accounts (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), pluggy_id text NOT NULL UNIQUE,
 item_id uuid NOT NULL REFERENCES finance.items(id), type text NOT NULL CHECK(type IN ('BANK','CREDIT')),
 subtype text, name text NOT NULL, number_masked text, currency char(3) NOT NULL DEFAULT 'BRL',
 balance numeric(14,2), balance_observed_at timestamptz, credit_limit numeric(14,2),
 available_credit_limit numeric(14,2), raw jsonb NOT NULL DEFAULT '{}'::jsonb, deleted_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (jsonb_typeof(raw)='object')
);

CREATE TABLE IF NOT EXISTS finance.cards (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), account_id uuid NOT NULL REFERENCES finance.accounts(id),
 last4 text NOT NULL CHECK(last4 ~ '^[0-9]{4}$'), label text, brand text, active boolean NOT NULL DEFAULT true,
 raw jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(account_id,last4), UNIQUE(id,account_id)
);

CREATE TABLE IF NOT EXISTS finance.credit_card_bills (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), pluggy_id text NOT NULL UNIQUE,
 account_id uuid NOT NULL REFERENCES finance.accounts(id), due_date date NOT NULL, closing_date date,
 total_amount numeric(14,2) NOT NULL, currency char(3) NOT NULL DEFAULT 'BRL', minimum_payment_amount numeric(14,2),
 allows_installments boolean, finance_charges jsonb NOT NULL DEFAULT '[]', payments jsonb NOT NULL DEFAULT '[]',
 provider_created_at timestamptz, provider_updated_at timestamptz, raw jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(id,account_id)
);

CREATE TABLE IF NOT EXISTS finance.pluggy_categories (
 id text PRIMARY KEY, description text NOT NULL, description_pt text NOT NULL, parent_id text REFERENCES finance.pluggy_categories(id), raw jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS finance.categories (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), name text NOT NULL, slug text NOT NULL UNIQUE,
 parent_id uuid REFERENCES finance.categories(id), counts_as_expense boolean NOT NULL DEFAULT true,
 active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS finance.category_mappings (
 pluggy_category_id text PRIMARY KEY REFERENCES finance.pluggy_categories(id), user_category_id uuid NOT NULL REFERENCES finance.categories(id),
 origin text NOT NULL DEFAULT 'seed' CHECK(origin IN ('seed','user')),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE finance.category_mappings ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'seed';

CREATE TABLE IF NOT EXISTS finance.merchants (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), name text NOT NULL, normalized_name text NOT NULL,
 document_number text UNIQUE, active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS finance.merchant_aliases (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), merchant_id uuid NOT NULL REFERENCES finance.merchants(id),
 alias text NOT NULL, normalized_alias text NOT NULL UNIQUE, origin text NOT NULL CHECK(origin IN ('manual','pluggy','learned')),
 confidence numeric(4,3) NOT NULL CHECK(confidence BETWEEN 0 AND 1), created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS finance.sync_runs (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), mode text NOT NULL CHECK(mode IN ('backfill','full','webhook','drain')),
 item_id uuid REFERENCES finance.items(id), account_id uuid REFERENCES finance.accounts(id), status text NOT NULL DEFAULT 'processing' CHECK(status IN ('processing','done','failed','partial')),
 date_from date, accounts_count integer NOT NULL DEFAULT 0 CHECK(accounts_count>=0), transactions_count integer NOT NULL DEFAULT 0 CHECK(transactions_count>=0),
 started_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz, error jsonb
);

CREATE TABLE IF NOT EXISTS finance.webhook_events (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), event_id text NOT NULL UNIQUE, event text NOT NULL,
 item_pluggy_id text, account_pluggy_id text, payload jsonb NOT NULL, status text NOT NULL DEFAULT 'received' CHECK(status IN ('received','processing','done','failed','ignored')),
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts>=0), last_error text, received_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz
);

CREATE TABLE IF NOT EXISTS finance.transactions (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), source text NOT NULL CHECK(source IN ('pluggy','manual','sheet_import')),
 pluggy_id text UNIQUE, source_key text, account_id uuid REFERENCES finance.accounts(id), card_id uuid, bill_id uuid,
 pluggy_bill_id text, booking_date date NOT NULL, purchase_date date, occurred_at timestamptz,
 description text NOT NULL, description_raw text, merchant_id uuid REFERENCES finance.merchants(id), merchant_normalized text NOT NULL DEFAULT '',
 original_amount numeric(14,2) NOT NULL, original_currency char(3) NOT NULL DEFAULT 'BRL', amount_in_account_currency numeric(14,2),
 signed_amount numeric(14,2), currency char(3) NOT NULL DEFAULT 'BRL', normalization_status text NOT NULL CHECK(normalization_status IN ('ready','needs_review')),
 pluggy_type text, status text NOT NULL CHECK(status IN ('pending','posted')), economic_type text NOT NULL CHECK(economic_type IN ('expense','income','refund','internal_transfer','card_payment','investment','unknown')),
 economic_type_override text CHECK(economic_type_override IN ('expense','income','refund','internal_transfer','card_payment','investment','unknown')),
 pluggy_category_id text REFERENCES finance.pluggy_categories(id), user_category_id uuid REFERENCES finance.categories(id), expense_override boolean,
 installment_number integer CHECK(installment_number>0), total_installments integer CHECK(total_installments>0), installment_total_amount numeric(14,2),
 bill_forecast_month date, bill_post_date date, provider_created_at timestamptz, provider_updated_at timestamptz,
 raw jsonb NOT NULL DEFAULT '{}', payload_hash text NOT NULL, revision_no bigint NOT NULL DEFAULT 1 CHECK(revision_no>=1),
 first_seen_at timestamptz NOT NULL DEFAULT now(), last_seen_at timestamptz NOT NULL DEFAULT now(), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 deleted_at timestamptz, deletion_reason text,
 FOREIGN KEY(card_id,account_id) REFERENCES finance.cards(id,account_id), FOREIGN KEY(bill_id,account_id) REFERENCES finance.credit_card_bills(id,account_id),
 CHECK ((source='pluggy' AND pluggy_id IS NOT NULL AND account_id IS NOT NULL) OR (source<>'pluggy' AND source_key IS NOT NULL AND pluggy_id IS NULL)),
 CHECK (normalization_status<>'ready' OR (signed_amount IS NOT NULL AND currency='BRL')),
 CHECK (installment_number IS NULL OR total_installments IS NULL OR installment_number<=total_installments),
 CHECK (bill_forecast_month IS NULL OR bill_forecast_month=date_trunc('month',bill_forecast_month)::date), CHECK(jsonb_typeof(raw)='object')
);

CREATE UNIQUE INDEX IF NOT EXISTS transactions_source_key_uidx ON finance.transactions(source,source_key) WHERE source<>'pluggy';

CREATE TABLE IF NOT EXISTS finance.transaction_revisions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, transaction_id uuid NOT NULL REFERENCES finance.transactions(id), revision_no bigint NOT NULL,
 changed_at timestamptz NOT NULL DEFAULT now(), actor text NOT NULL DEFAULT 'database', reason text, before_data jsonb, after_data jsonb NOT NULL,
 sync_run_id uuid REFERENCES finance.sync_runs(id), webhook_event_id uuid REFERENCES finance.webhook_events(id), UNIQUE(transaction_id,revision_no)
);

CREATE TABLE IF NOT EXISTS finance.reconciliations (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), manual_tx_id uuid NOT NULL REFERENCES finance.transactions(id), pluggy_tx_id uuid NOT NULL REFERENCES finance.transactions(id),
 status text NOT NULL CHECK(status IN ('active','suggested','rejected','undone')), score numeric(4,3) CHECK(score BETWEEN 0 AND 1),
 method text NOT NULL CHECK(method IN ('auto','user')), evidence jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now(), ended_at timestamptz,
 CHECK(manual_tx_id<>pluggy_tx_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS reconciliations_manual_active_uidx ON finance.reconciliations(manual_tx_id) WHERE status='active';

CREATE UNIQUE INDEX IF NOT EXISTS reconciliations_pluggy_active_uidx ON finance.reconciliations(pluggy_tx_id) WHERE status='active';

CREATE TABLE IF NOT EXISTS finance.budgets (
 id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(), name text NOT NULL, start_date date NOT NULL, end_date_exclusive date NOT NULL,
 amount numeric(14,2) NOT NULL CHECK(amount>=0), currency char(3) NOT NULL DEFAULT 'BRL' CHECK(currency='BRL'),
 category_id uuid REFERENCES finance.categories(id), reserve_pending boolean NOT NULL DEFAULT true, active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), CHECK(start_date<end_date_exclusive), UNIQUE(name,start_date,end_date_exclusive)
);


CREATE INDEX IF NOT EXISTS accounts_item_idx ON finance.accounts(item_id);

CREATE INDEX IF NOT EXISTS cards_account_idx ON finance.cards(account_id);

CREATE INDEX IF NOT EXISTS bills_account_due_idx ON finance.credit_card_bills(account_id,due_date DESC);

CREATE INDEX IF NOT EXISTS tx_account_date_idx ON finance.transactions(account_id,booking_date DESC) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS tx_card_date_idx ON finance.transactions(card_id,booking_date DESC) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS tx_bill_idx ON finance.transactions(bill_id);
 CREATE INDEX IF NOT EXISTS tx_merchant_date_idx ON finance.transactions(merchant_id,booking_date);

CREATE INDEX IF NOT EXISTS tx_category_idx ON finance.transactions(pluggy_category_id);
 CREATE INDEX IF NOT EXISTS tx_user_category_idx ON finance.transactions(user_category_id);

CREATE INDEX IF NOT EXISTS tx_reconcile_idx ON finance.transactions(signed_amount,booking_date) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS tx_merchant_trgm_idx ON finance.transactions USING gin(merchant_normalized extensions.gin_trgm_ops);

CREATE INDEX IF NOT EXISTS alias_trgm_idx ON finance.merchant_aliases USING gin(normalized_alias extensions.gin_trgm_ops);

CREATE INDEX IF NOT EXISTS webhook_queue_idx ON finance.webhook_events(status,updated_at) WHERE attempts<5;
