defmodule BillingCore.Repo.Migrations.IndexProviderPaymentGrants do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Store payments (App Store, Google Play) link their grants by
  # `metadata->>'provider_payment_id'`. Refunds look grants up by that value.
  def up do
    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS credit_grants_provider_payment_idx ON credit_grants ((metadata->>'provider_payment_id')) WHERE metadata ? 'provider_payment_id'"
    )
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS credit_grants_provider_payment_idx")
  end
end
