defmodule BridgeForTeams.Repo.Migrations.DropEnvironmentsTable do
  @moduledoc """
  Salix is now the source of truth for remote environments: BridgeForTeams reads
  the live `SalixEnv.Registry` records over `:erpc` and keeps no Postgres mirror
  (and runs no reconcile). Drop the now-unused `environments` table.

  `down/0` recreates it to mirror the original `create_core_tables` shape so the
  migration is reversible.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:environments)
  end

  def down do
    create table(:environments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :salix_env_id, :string
      add :name, :string
      add :status, :string, null: false, default: "pending"
      add :connector_token_hash, :string
      add :last_seen_at, :utc_datetime_usec
      add :meta, :map

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create index(:environments, [:project_id])
    create unique_index(:environments, [:salix_env_id])
  end
end
