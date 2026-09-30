defmodule BridgeForTeams.Repo.Migrations.CreateMacMiniProvisioningTables do
  @moduledoc """
  Org-scoped Mac mini runner control-plane slice for project devices.

  Salix remains the source of truth for connector runs and discovered runtimes;
  these tables track runner availability and project device requests.
  """
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def change do
    create_if_not_exists table(:mac_mini_provisioners, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :stable_id, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "online"
      add :host_identity, :string
      add :os_summary, :string
      add :version, :string
      add :capabilities, :map
      add :capacity, :integer, null: false, default: 1
      add :current_connector_count, :integer, null: false, default: 0
      add :last_seen_at, :utc_datetime_usec

      timestamps(@ts)
    end

    create_if_not_exists unique_index(:mac_mini_provisioners, [:org_id, :stable_id])
    create_if_not_exists index(:mac_mini_provisioners, [:org_id, :status])

    create_if_not_exists table(:environment_provision_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provisioner_id,
          references(:mac_mini_provisioners, type: :binary_id, on_delete: :nilify_all)

      add :salix_group_id, :string, null: false
      add :name, :string, null: false
      add :env_alias, :string
      add :execution_boundary, :string, null: false, default: "fin-supervisor"
      add :status, :string, null: false, default: "pending"
      add :failure_code, :string
      add :failure_message, :string
      add :connector_run_id, :string
      add :connector_token_hash, :string
      add :spec, :map

      timestamps(@ts)
    end

    create_if_not_exists index(:environment_provision_requests, [:project_id, :status])
    create_if_not_exists index(:environment_provision_requests, [:provisioner_id, :status])
    create_if_not_exists index(:environment_provision_requests, [:connector_run_id])
  end
end
