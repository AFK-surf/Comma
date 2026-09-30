defmodule SalixStore.Repo.Migrations.IndexPendingTriageRecovery do
  use Ecto.Migration

  def change do
    create(
      index(:triage_run_fences, [:namespace_key, :record_key],
        name: :triage_open_fences_recovery_idx,
        where: "body -> 'terminal' = 'null'::jsonb"
      )
    )

    create(
      index(:triage_buckets, [:namespace_key, :record_key],
        name: :triage_buckets_recovery_page_idx
      )
    )

    create(
      index(:triage_projection_obligations, [:namespace_key, :updated_at, :run_id],
        name: :triage_projection_obligations_namespace_pending_idx,
        where: "state = 'pending'"
      )
    )
  end
end
