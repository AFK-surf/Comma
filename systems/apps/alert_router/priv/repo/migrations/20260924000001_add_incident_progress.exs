defmodule AlertRouter.Repo.Migrations.AddIncidentProgress do
  use Ecto.Migration

  def change do
    alter table(:alert_router_incidents) do
      add(:progress, :map, null: false, default: %{})
      add(:slack_root_revision, :bigint)
    end

    create(index(:alert_router_incidents, [:channel_id, :slack_root_ts]))
  end
end
