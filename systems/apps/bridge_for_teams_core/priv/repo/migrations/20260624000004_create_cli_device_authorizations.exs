defmodule BridgeForTeams.Repo.Migrations.CreateCliDeviceAuthorizations do
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def change do
    alter table(:auth_sessions) do
      add :client_name, :string
    end

    create table(:cli_device_authorizations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_code, :string, null: false
      add :device_code_hash, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :client_name, :string
      add :created_by_ip, :string

      add :approved_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :cancelled_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :approved_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :consumed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      add :last_polled_at, :utc_datetime_usec

      timestamps(@ts)
    end

    create unique_index(:cli_device_authorizations, [:user_code])
    create unique_index(:cli_device_authorizations, [:device_code_hash])
    create index(:cli_device_authorizations, [:status])
    create index(:cli_device_authorizations, [:approved_by_user_id])
  end
end
