defmodule BillingCore.Repo.Migrations.AddCyclePaymentSources do
  use Ecto.Migration

  def up do
    alter table(:billing_subscription_cycles) do
      add(:source_metadata, :map, null: false, default: %{})
    end

    execute("""
    CREATE FUNCTION pg_temp.comma_billing_object(input jsonb) RETURNS jsonb
    LANGUAGE plpgsql AS $$
    DECLARE item jsonb; result jsonb := '{}'::jsonb;
    BEGIN
      CASE jsonb_typeof(input)
        WHEN 'string' THEN RETURN pg_temp.comma_billing_object((input #>> '{}')::jsonb);
        WHEN 'array' THEN
          FOR item IN SELECT value FROM jsonb_array_elements(input) LOOP
            result := result || pg_temp.comma_billing_object(item);
          END LOOP;
          RETURN result || jsonb_build_object('_legacy_updates', input);
        WHEN 'object' THEN RETURN input;
        ELSE RAISE EXCEPTION 'invalid_comma_billing_metadata';
      END CASE;
    END $$;
    """)

    for {table, column, condition} <- [
          {"billing_packages", "metadata", "surface = 'comma'"},
          {"billing_package_versions", "usage_policy", "surface = 'comma'"},
          {"billing_provider_prices", "metadata",
           "package_code IN (SELECT code FROM billing_packages WHERE surface = 'comma')"},
          {"billing_provider_customers", "metadata", "surface = 'comma'"},
          {"billing_subscriptions", "source_metadata", "surface = 'comma'"},
          {"billing_one_time_purchases", "source_metadata", "surface = 'comma'"},
          {"credit_grants", "package_snapshot",
           "billing_account_id IN (SELECT id FROM billing_accounts WHERE surface = 'comma')"},
          {"credit_grants", "policy_snapshot",
           "billing_account_id IN (SELECT id FROM billing_accounts WHERE surface = 'comma')"},
          {"credit_grant_events", "snapshot",
           "billing_account_id IN (SELECT id FROM billing_accounts WHERE surface = 'comma')"},
          {"credit_grants", "metadata",
           "billing_account_id IN (SELECT id FROM billing_accounts WHERE surface = 'comma')"}
        ] do
      execute(
        "UPDATE #{table} SET #{column} = pg_temp.comma_billing_object(#{column}) WHERE #{condition} AND jsonb_typeof(#{column}) <> 'object'"
      )
    end

    execute(
      "CREATE INDEX credit_grants_stripe_invoice_idx ON credit_grants ((metadata->>'stripe_invoice_id')) WHERE metadata ? 'stripe_invoice_id'"
    )

    execute(
      "CREATE INDEX credit_grants_stripe_payment_idx ON credit_grants ((metadata->>'stripe_payment_intent_id')) WHERE metadata ? 'stripe_payment_intent_id'"
    )

    execute(
      "CREATE INDEX billing_cycles_payment_sources_idx ON billing_subscription_cycles USING gin ((source_metadata->'payment_sources'))"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS billing_cycles_payment_sources_idx")
    execute("DROP INDEX IF EXISTS credit_grants_stripe_payment_idx")
    execute("DROP INDEX IF EXISTS credit_grants_stripe_invoice_idx")

    alter table(:billing_subscription_cycles) do
      remove(:source_metadata)
    end
  end
end
