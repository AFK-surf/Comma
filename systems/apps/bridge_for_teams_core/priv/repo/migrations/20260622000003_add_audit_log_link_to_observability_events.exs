defmodule BridgeForTeams.Repo.Migrations.AddAuditLogLinkToObservabilityEvents do
  use Ecto.Migration

  def change do
    alter table(:observability_events) do
      add :audit_log_id, references(:audit_logs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:observability_events, [:org_id, :audit_log_id])
  end
end
