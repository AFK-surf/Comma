defmodule SalixStore.Repo.Migrations.CreateComputeReconcilerState do
  use Ecto.Migration

  # Durable keyset progress for bounded provider reconciliation. The cursor is
  # an operational projection, not Compute product state, and can be rebuilt
  # from Workloads if the provider owner is replaced.
  def change do
    create table(:compute_reconciler_cursors, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:provider, :text, null: false)
      add(:cursor_tenant_id, :text)
      add(:cursor_updated_at, :utc_datetime_usec)
      add(:cursor_workload_id, :text)
      add(:high_watermark_tenant_id, :text)
      add(:high_watermark_updated_at, :utc_datetime_usec)
      add(:high_watermark_workload_id, :text)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:compute_reconciler_cursors, [:provider]))

    create table(:compute_reconciler_claims, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:provider, :text, null: false)
      add(:workload_id, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:claim_token, :text, null: false)
      add(:attempt_count, :bigint, null: false, default: 0)
      add(:next_retry_at, :utc_datetime_usec)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:last_error, :map)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:compute_reconciler_claims, [:provider, :workload_id, :generation]))

    create(index(:compute_reconciler_claims, [:provider, :lease_expires_at, :next_retry_at]))
  end
end
