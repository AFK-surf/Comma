defmodule BridgeForTeams.Repo.Migrations.CreateOwnerNotifications do
  use Ecto.Migration

  def change do
    create table(:owner_notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :ref, :string, null: false
      add :dedupe_key, :string, null: false
      add :facts, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :send_after, :utc_datetime_usec, null: false
      add :sent_at, :utc_datetime_usec
      add :last_error, :string

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:owner_notifications, [:project_id, :dedupe_key])
    create index(:owner_notifications, [:send_after], where: "status = 'pending'")
  end
end
