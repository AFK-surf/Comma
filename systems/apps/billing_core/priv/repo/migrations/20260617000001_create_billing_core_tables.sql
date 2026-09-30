CREATE TABLE billing_accounts (
  id text PRIMARY KEY,
  surface text NOT NULL,
  product_owner_type text NOT NULL,
  product_owner_id text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (surface, product_owner_type, product_owner_id)
);

CREATE TABLE credit_balances (
  billing_account_id text PRIMARY KEY REFERENCES billing_accounts(id),
  balance_credits bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE credit_grants (
  id text PRIMARY KEY,
  billing_account_id text NOT NULL REFERENCES billing_accounts(id),
  remaining_credits bigint NOT NULL,
  expires_at timestamptz,
  priority integer NOT NULL DEFAULT 0,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX credit_grants_active_idx
  ON credit_grants (billing_account_id, expires_at, id)
  WHERE remaining_credits > 0;

CREATE TABLE meter_pricing_catalog (
  id text PRIMARY KEY,
  resource_kind text NOT NULL,
  provider text NOT NULL,
  sku text NOT NULL,
  component text NOT NULL,
  meter_unit text NOT NULL,
  usd_micros_per_unit numeric NOT NULL,
  credits_per_usd bigint NOT NULL DEFAULT 1000000,
  effective_at timestamptz NOT NULL,
  expires_at timestamptz,
  version text NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX meter_pricing_catalog_lookup_idx
  ON meter_pricing_catalog (resource_kind, provider, sku, component, effective_at, expires_at);

CREATE TABLE meter_aliases (
  id text PRIMARY KEY,
  resource_kind text NOT NULL,
  provider text NOT NULL,
  alias text NOT NULL,
  sku text NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (resource_kind, provider, alias)
);

CREATE TABLE storage_metering_scopes (
  id text PRIMARY KEY,
  billing_account_id text NOT NULL REFERENCES billing_accounts(id),
  provider text NOT NULL,
  bucket text NOT NULL,
  prefix text NOT NULL,
  owner_snapshot jsonb NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE storage_metering_checkpoints (
  scope_id text PRIMARY KEY REFERENCES storage_metering_scopes(id),
  sampled_at timestamptz NOT NULL,
  object_count bigint NOT NULL,
  bytes bigint NOT NULL
);

CREATE TABLE meter_rounding_remainders (
  billing_account_id text NOT NULL REFERENCES billing_accounts(id),
  resource_kind text NOT NULL,
  provider text NOT NULL,
  sku text NOT NULL,
  remainder_credits numeric NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (billing_account_id, resource_kind, provider, sku)
);

CREATE TABLE pending_meter_charges (
  id text PRIMARY KEY,
  billing_account_id text NOT NULL REFERENCES billing_accounts(id),
  source_key text NOT NULL,
  resource_kind text NOT NULL,
  provider text NOT NULL,
  sku text NOT NULL,
  meter_snapshot jsonb NOT NULL,
  status text NOT NULL,
  metered_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (billing_account_id, source_key)
);

CREATE INDEX pending_meter_charges_backfill_idx
  ON pending_meter_charges (status, expires_at, id);

CREATE TABLE credit_ledger (
  id text PRIMARY KEY,
  billing_account_id text NOT NULL REFERENCES billing_accounts(id),
  source_key text NOT NULL,
  resource_kind text NOT NULL,
  provider text NOT NULL,
  sku text NOT NULL,
  pricing_components jsonb NOT NULL,
  credits_per_usd bigint NOT NULL DEFAULT 1000000,
  calculated_credits bigint NOT NULL,
  charged_credits bigint NOT NULL,
  grace_credits bigint NOT NULL,
  balance_after bigint NOT NULL,
  status text NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (billing_account_id, source_key)
);

CREATE TABLE billing_repair_audit (
  id text PRIMARY KEY,
  table_name text NOT NULL,
  row_id text NOT NULL,
  operation text NOT NULL,
  reason text NOT NULL,
  actor text NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION billing_core_forbid_mutation()
RETURNS trigger AS $$
BEGIN
  IF current_setting('billing_core.repair_mode', true) = 'on'
     AND to_regrole('billing_repair') IS NOT NULL
     AND pg_has_role(current_user, 'billing_repair', 'USAGE') THEN
    INSERT INTO billing_repair_audit (
      id,
      table_name,
      row_id,
      operation,
      reason,
      actor
    ) VALUES (
      md5(TG_TABLE_NAME || ':' || TG_OP || ':' || COALESCE(OLD.id, NEW.id) || ':' || clock_timestamp()::text),
      TG_TABLE_NAME,
      COALESCE(OLD.id, NEW.id),
      TG_OP,
      COALESCE(current_setting('billing_core.repair_reason', true), 'unspecified'),
      COALESCE(current_setting('billing_core.repair_actor', true), current_user)
    );

    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    ELSE
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'billing_core table % is append-only for application role', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER meter_pricing_catalog_append_only
  BEFORE UPDATE OR DELETE ON meter_pricing_catalog
  FOR EACH ROW EXECUTE FUNCTION billing_core_forbid_mutation();

CREATE TRIGGER meter_aliases_append_only
  BEFORE UPDATE OR DELETE ON meter_aliases
  FOR EACH ROW EXECUTE FUNCTION billing_core_forbid_mutation();

CREATE TRIGGER credit_ledger_append_only
  BEFORE UPDATE OR DELETE ON credit_ledger
  FOR EACH ROW EXECUTE FUNCTION billing_core_forbid_mutation();

-- Controlled repair/migration sessions must run as a role that has
-- billing_repair and set billing_core.repair_mode=on so the trigger records an
-- audit row before allowing UPDATE/DELETE.
