defmodule AlertRouter.Repo.Migrations.AddIncidentHandlingRevision do
  use Ecto.Migration

  def change do
    alter table(:alert_router_incidents) do
      add(:handling_revision, :bigint, null: false, default: 0)
      add(:feedback, :map, null: false, default: %{})
    end
  end
end
