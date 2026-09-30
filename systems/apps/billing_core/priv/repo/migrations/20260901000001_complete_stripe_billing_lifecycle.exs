defmodule BillingCore.Repo.Migrations.CompleteStripeBillingLifecycle do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    ALTER TABLE billing_one_time_purchases
      ADD COLUMN IF NOT EXISTS provider_payment_intent_id text,
      ADD COLUMN IF NOT EXISTS refunded_amount_minor bigint NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS refunded_credits bigint NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS refunded_at timestamptz
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM billing_one_time_purchases
        WHERE provider_payment_intent_id IS NOT NULL
        GROUP BY provider_payment_intent_id
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'billing_one_time_purchases_payment_intent_duplicates';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM credit_grant_events
        WHERE idempotency_key IS NOT NULL
        GROUP BY billing_account_id, idempotency_key
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'credit_grant_events_account_idempotency_duplicates';
      END IF;
    END
    $$
    """)

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS billing_one_time_purchases_payment_intent_idx
      ON billing_one_time_purchases (provider_payment_intent_id)
      WHERE provider_payment_intent_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS credit_grant_events_account_idempotency_idx
      ON credit_grant_events (billing_account_id, idempotency_key)
      WHERE idempotency_key IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS credit_grant_events_account_idempotency_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS billing_one_time_purchases_payment_intent_idx")

    execute("""
    ALTER TABLE billing_one_time_purchases
      DROP COLUMN IF EXISTS refunded_at,
      DROP COLUMN IF EXISTS refunded_credits,
      DROP COLUMN IF EXISTS refunded_amount_minor,
      DROP COLUMN IF EXISTS provider_payment_intent_id
    """)
  end
end
