defmodule BillingCore.Repo.Migrations.CreateBillingCommerceTables do
  use Ecto.Migration

  def up do
    extend_credit_facts()

    execute("""
    CREATE TABLE billing_packages (
      code text PRIMARY KEY,
      surface text NOT NULL,
      name text NOT NULL,
      status text NOT NULL DEFAULT 'active',
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE TABLE billing_package_versions (
      id text PRIMARY KEY,
      package_code text NOT NULL REFERENCES billing_packages(code),
      version text NOT NULL,
      surface text NOT NULL,
      kind text NOT NULL,
      billing_period text NOT NULL,
      grant_credits bigint NOT NULL,
      grant_period text NOT NULL,
      currency text NOT NULL,
      amount_minor bigint NOT NULL,
      usage_policy jsonb NOT NULL DEFAULT '{}'::jsonb,
      effective_at timestamptz NOT NULL,
      expires_at timestamptz,
      status text NOT NULL DEFAULT 'active',
      inserted_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (package_code, version)
    )
    """)

    execute("""
    CREATE INDEX billing_package_versions_lookup_idx
      ON billing_package_versions (package_code, version, status, effective_at, expires_at)
    """)

    execute("""
    CREATE TABLE billing_provider_prices (
      id text PRIMARY KEY,
      package_code text NOT NULL,
      package_version text NOT NULL,
      provider text NOT NULL,
      provider_lookup_key text,
      provider_price_id text NOT NULL,
      currency text,
      amount_minor bigint,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (provider, provider_price_id),
      FOREIGN KEY (package_code, package_version)
        REFERENCES billing_package_versions(package_code, version)
    )
    """)

    execute("""
    CREATE INDEX billing_provider_prices_package_idx
      ON billing_provider_prices (package_code, package_version, provider)
    """)

    execute("""
    CREATE UNIQUE INDEX billing_provider_prices_lookup_key_idx
      ON billing_provider_prices (provider, provider_lookup_key)
      WHERE provider_lookup_key IS NOT NULL
    """)

    execute("""
    CREATE TABLE billing_provider_customers (
      id text PRIMARY KEY,
      billing_account_id text NOT NULL REFERENCES billing_accounts(id),
      surface text NOT NULL,
      product_owner_type text NOT NULL,
      product_owner_id text NOT NULL,
      provider text NOT NULL,
      provider_context text NOT NULL DEFAULT 'default',
      provider_customer_id text NOT NULL,
      status text NOT NULL DEFAULT 'active',
      billing_email_snapshot text,
      display_name_snapshot text,
      created_by_actor_type text,
      created_by_actor_id text,
      source_type text NOT NULL,
      source_event_id text,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX billing_provider_customers_account_provider_idx
      ON billing_provider_customers (billing_account_id, provider, provider_context)
      WHERE status = 'active'
    """)

    execute("""
    CREATE UNIQUE INDEX billing_provider_customers_provider_customer_idx
      ON billing_provider_customers (provider, provider_context, provider_customer_id)
    """)

    execute("""
    CREATE INDEX billing_provider_customers_owner_idx
      ON billing_provider_customers (
        surface, product_owner_type, product_owner_id, provider, provider_context
      )
    """)

    execute("""
    CREATE TABLE billing_manual_grants (
      id text PRIMARY KEY,
      billing_account_id text NOT NULL REFERENCES billing_accounts(id),
      package_code text NOT NULL,
      package_version text NOT NULL,
      source_type text NOT NULL,
      source_id text NOT NULL,
      source_event_id text NOT NULL,
      idempotency_key text NOT NULL,
      operator_snapshot jsonb NOT NULL,
      period_start timestamptz NOT NULL,
      period_end timestamptz NOT NULL,
      credit_grant_id text REFERENCES credit_grants(id),
      status text NOT NULL DEFAULT 'pending',
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (billing_account_id, idempotency_key),
      FOREIGN KEY (package_code, package_version)
        REFERENCES billing_package_versions(package_code, version)
    )
    """)

    execute("""
    CREATE INDEX billing_manual_grants_account_time_idx
      ON billing_manual_grants (billing_account_id, inserted_at DESC, id)
    """)

    execute("""
    CREATE TABLE billing_subscriptions (
      id text PRIMARY KEY,
      billing_account_id text NOT NULL REFERENCES billing_accounts(id),
      surface text NOT NULL,
      product_owner_type text NOT NULL,
      product_owner_id text NOT NULL,
      package_code text NOT NULL,
      package_version text NOT NULL,
      source_type text NOT NULL,
      source_id text NOT NULL,
      source_event_id text NOT NULL,
      idempotency_key text NOT NULL,
      source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      status text NOT NULL DEFAULT 'active',
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (billing_account_id, idempotency_key),
      FOREIGN KEY (package_code, package_version)
        REFERENCES billing_package_versions(package_code, version)
    )
    """)

    execute("""
    CREATE INDEX billing_subscriptions_account_status_idx
      ON billing_subscriptions (billing_account_id, status, inserted_at DESC, id)
    """)

    execute("""
    CREATE TABLE billing_subscription_cycles (
      id text PRIMARY KEY,
      subscription_id text NOT NULL REFERENCES billing_subscriptions(id),
      billing_account_id text NOT NULL REFERENCES billing_accounts(id),
      package_code text NOT NULL,
      package_version text NOT NULL,
      cycle_key text NOT NULL,
      period_start timestamptz NOT NULL,
      period_end timestamptz NOT NULL,
      grant_idempotency_key text NOT NULL,
      grant_source_type text NOT NULL DEFAULT 'subscription_cycle',
      source_event_id text NOT NULL,
      credit_grant_id text REFERENCES credit_grants(id),
      status text NOT NULL DEFAULT 'pending',
      attempts integer NOT NULL DEFAULT 0,
      last_error text,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (subscription_id, cycle_key),
      UNIQUE (billing_account_id, grant_idempotency_key),
      FOREIGN KEY (package_code, package_version)
        REFERENCES billing_package_versions(package_code, version)
    )
    """)

    execute("""
    CREATE INDEX billing_subscription_cycles_due_idx
      ON billing_subscription_cycles (status, period_start, id)
      WHERE status IN ('pending', 'failed')
    """)

    execute("""
    CREATE TABLE billing_one_time_purchases (
      id text PRIMARY KEY,
      billing_account_id text NOT NULL REFERENCES billing_accounts(id),
      surface text NOT NULL,
      product_owner_type text NOT NULL,
      product_owner_id text NOT NULL,
      package_code text NOT NULL,
      package_version text NOT NULL,
      source_type text NOT NULL,
      source_id text NOT NULL,
      source_event_id text NOT NULL,
      idempotency_key text NOT NULL,
      source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      period_start timestamptz NOT NULL,
      period_end timestamptz NOT NULL,
      credit_grant_id text REFERENCES credit_grants(id),
      status text NOT NULL DEFAULT 'pending',
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (billing_account_id, idempotency_key),
      FOREIGN KEY (package_code, package_version)
        REFERENCES billing_package_versions(package_code, version)
    )
    """)

    execute("""
    CREATE INDEX billing_one_time_purchases_account_time_idx
      ON billing_one_time_purchases (billing_account_id, inserted_at DESC, id)
    """)

    execute("""
    CREATE TABLE billing_stripe_events (
      id text PRIMARY KEY,
      payload_digest text NOT NULL,
      event_type text NOT NULL,
      object_id text,
      object_type text,
      status text NOT NULL,
      error text,
      processed_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX billing_stripe_events_type_time_idx
      ON billing_stripe_events (event_type, inserted_at DESC)
    """)

    execute("""
    CREATE TABLE billing_redeem_codes (
      id text PRIMARY KEY,
      code_hash text NOT NULL UNIQUE,
      display_prefix text NOT NULL,
      package_code text NOT NULL,
      package_version text NOT NULL,
      code_type text NOT NULL,
      surface text NOT NULL,
      scope_product_owner_type text,
      scope_product_owner_id text,
      status text NOT NULL DEFAULT 'active',
      max_redemptions integer,
      per_account_limit integer NOT NULL DEFAULT 1,
      valid_from timestamptz NOT NULL,
      expires_at timestamptz,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      FOREIGN KEY (package_code, package_version)
        REFERENCES billing_package_versions(package_code, version)
    )
    """)

    execute("""
    CREATE INDEX billing_redeem_codes_status_time_idx
      ON billing_redeem_codes (status, expires_at, id)
    """)

    execute("""
    CREATE TABLE billing_redemptions (
      id text PRIMARY KEY,
      redeem_code_id text NOT NULL REFERENCES billing_redeem_codes(id),
      billing_account_id text NOT NULL REFERENCES billing_accounts(id),
      surface text NOT NULL,
      product_owner_type text NOT NULL,
      product_owner_id text NOT NULL,
      source_type text NOT NULL,
      source_id text,
      source_event_id text NOT NULL,
      idempotency_key text NOT NULL,
      operator_snapshot jsonb NOT NULL,
      status text NOT NULL DEFAULT 'pending',
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (billing_account_id, idempotency_key)
    )
    """)

    execute("""
    CREATE INDEX billing_redemptions_code_account_idx
      ON billing_redemptions (redeem_code_id, billing_account_id, inserted_at DESC, id)
    """)

    seed_openai_gpt52_llm_pricing()
  end

  def down do
    execute("DROP TABLE IF EXISTS billing_redemptions")
    execute("DROP TABLE IF EXISTS billing_redeem_codes")
    execute("DROP TABLE IF EXISTS billing_stripe_events")
    execute("DROP TABLE IF EXISTS billing_one_time_purchases")
    execute("DROP TABLE IF EXISTS billing_subscription_cycles")
    execute("DROP TABLE IF EXISTS billing_subscriptions")
    execute("DROP TABLE IF EXISTS billing_manual_grants")
    execute("DROP TABLE IF EXISTS billing_provider_customers")
    execute("DROP TABLE IF EXISTS billing_provider_prices")
    execute("DROP TABLE IF EXISTS billing_package_versions")
    execute("DROP TABLE IF EXISTS billing_packages")

    revert_credit_facts()
  end

  defp extend_credit_facts do
    execute("""
    ALTER TABLE credit_grants
      ADD COLUMN IF NOT EXISTS original_credits bigint,
      ADD COLUMN IF NOT EXISTS valid_from timestamptz,
      ADD COLUMN IF NOT EXISTS source_type text,
      ADD COLUMN IF NOT EXISTS source_id text,
      ADD COLUMN IF NOT EXISTS source_event_id text,
      ADD COLUMN IF NOT EXISTS idempotency_key text,
      ADD COLUMN IF NOT EXISTS package_code text,
      ADD COLUMN IF NOT EXISTS package_version text,
      ADD COLUMN IF NOT EXISTS package_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
      ADD COLUMN IF NOT EXISTS policy_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
      ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
      ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      ADD COLUMN IF NOT EXISTS updated_at timestamptz
    """)

    execute("""
    UPDATE credit_grants
    SET original_credits = COALESCE(original_credits, remaining_credits),
        valid_from = COALESCE(valid_from, inserted_at),
        source_type = COALESCE(source_type, 'legacy_grant'),
        idempotency_key = COALESCE(idempotency_key, id),
        updated_at = COALESCE(updated_at, inserted_at, now())
    """)

    execute("""
    ALTER TABLE credit_grants
      ALTER COLUMN original_credits SET NOT NULL,
      ALTER COLUMN valid_from SET NOT NULL,
      ALTER COLUMN source_type SET NOT NULL,
      ALTER COLUMN idempotency_key SET NOT NULL,
      ALTER COLUMN updated_at SET DEFAULT now(),
      ALTER COLUMN updated_at SET NOT NULL
    """)

    execute("DROP INDEX IF EXISTS credit_grants_active_idx")

    execute("""
    CREATE INDEX credit_grants_active_idx
      ON credit_grants (billing_account_id, valid_from, expires_at, priority, id)
      WHERE status = 'active' AND remaining_credits > 0
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS credit_grants_account_idempotency_idx
      ON credit_grants (billing_account_id, idempotency_key)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS credit_grant_events (
      id text PRIMARY KEY,
      billing_account_id text NOT NULL REFERENCES billing_accounts(id),
      credit_grant_id text REFERENCES credit_grants(id),
      event_type text NOT NULL,
      source_type text,
      source_id text,
      source_event_id text,
      idempotency_key text,
      credits_delta bigint NOT NULL DEFAULT 0,
      snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS credit_grant_events_account_time_idx
      ON credit_grant_events (billing_account_id, inserted_at DESC, id)
    """)

    execute("""
    ALTER TABLE credit_ledger
      ADD COLUMN IF NOT EXISTS grant_debits jsonb NOT NULL DEFAULT '[]'::jsonb,
      ADD COLUMN IF NOT EXISTS balance_after_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS credit_ledger_account_time_idx
      ON credit_ledger (billing_account_id, inserted_at DESC, id)
    """)
  end

  defp revert_credit_facts do
    execute("DROP INDEX IF EXISTS credit_ledger_account_time_idx")

    execute("""
    ALTER TABLE credit_ledger
      DROP COLUMN IF EXISTS balance_after_snapshot,
      DROP COLUMN IF EXISTS grant_debits
    """)

    execute("DROP TABLE IF EXISTS credit_grant_events")
    execute("DROP INDEX IF EXISTS credit_grants_account_idempotency_idx")
    execute("DROP INDEX IF EXISTS credit_grants_active_idx")

    execute("""
    CREATE INDEX credit_grants_active_idx
      ON credit_grants (billing_account_id, expires_at, id)
      WHERE remaining_credits > 0
    """)

    execute("""
    ALTER TABLE credit_grants
      DROP COLUMN IF EXISTS updated_at,
      DROP COLUMN IF EXISTS metadata,
      DROP COLUMN IF EXISTS status,
      DROP COLUMN IF EXISTS policy_snapshot,
      DROP COLUMN IF EXISTS package_snapshot,
      DROP COLUMN IF EXISTS package_version,
      DROP COLUMN IF EXISTS package_code,
      DROP COLUMN IF EXISTS idempotency_key,
      DROP COLUMN IF EXISTS source_event_id,
      DROP COLUMN IF EXISTS source_id,
      DROP COLUMN IF EXISTS source_type,
      DROP COLUMN IF EXISTS valid_from,
      DROP COLUMN IF EXISTS original_credits
    """)
  end

  def openai_gpt52_prices do
    flat_llm("openai", [
      {"gpt-5.2", 1.75, 14.0, 0.175},
      {"gpt-5.1", 1.25, 10.0, 0.125},
      {"gpt-5-mini", 0.25, 2.0, 0.025},
      {"gpt-5-nano", 0.05, 0.4, 0.005}
    ])
  end

  defp seed_openai_gpt52_llm_pricing do
    Enum.each(openai_gpt52_prices(), &insert_meter_price/1)
  end

  defp flat_llm(provider, specs) do
    Enum.flat_map(specs, fn {sku, input, output, cache_read} ->
      llm_prices(provider, sku, input, output, cache_read, input)
    end)
  end

  defp llm_prices(provider, sku, input, output, cache_read, cache_write) do
    [
      meter_price(provider, sku, "input", input),
      meter_price(provider, sku, "output", output),
      meter_price(provider, sku, "cache_read", cache_read),
      meter_price(provider, sku, "cache_write", cache_write)
    ]
    |> Enum.reject(&is_nil(&1.usd_micros_per_unit))
  end

  defp meter_price(provider, sku, component, usd_micros_per_unit) do
    %{
      id: "official-api-2026-06:llm:#{provider}:#{sku}:#{component}",
      resource_kind: "llm",
      provider: provider,
      sku: sku,
      component: component,
      meter_unit: "token",
      usd_micros_per_unit: usd_micros_per_unit,
      version: "official-api-2026-06",
      effective_at: "2026-06-17 00:00:00Z"
    }
  end

  defp insert_meter_price(price) do
    execute("""
    INSERT INTO meter_pricing_catalog (
      id,
      resource_kind,
      provider,
      sku,
      component,
      meter_unit,
      usd_micros_per_unit,
      credits_per_usd,
      effective_at,
      expires_at,
      version,
      inserted_at
    ) VALUES (
      '#{escape(price.id)}',
      '#{escape(price.resource_kind)}',
      '#{escape(price.provider)}',
      '#{escape(price.sku)}',
      '#{escape(price.component)}',
      '#{escape(price.meter_unit)}',
      #{price.usd_micros_per_unit},
      1000000,
      TIMESTAMPTZ '#{price.effective_at}',
      NULL,
      '#{escape(price.version)}',
      now()
    )
    ON CONFLICT (id) DO NOTHING
    """)
  end

  defp escape(value), do: value |> to_string() |> String.replace("'", "''")
end
