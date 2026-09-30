defmodule BridgeForTeams.Repo.Migrations.CreateCliSessionOrgGrants do
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def change do
    alter table(:cli_device_authorizations) do
      add(:purpose, :string, null: false, default: "login")

      add(
        :auth_session_id,
        references(:auth_sessions, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create table(:cli_device_authorization_org_grants, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(
        :cli_device_authorization_id,
        references(:cli_device_authorizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(@ts)
    end

    create(
      unique_index(:cli_device_authorization_org_grants, [
        :cli_device_authorization_id,
        :org_id
      ])
    )

    create(index(:cli_device_authorization_org_grants, [:org_id]))

    create table(:cli_session_org_grants, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(:auth_session_id, references(:auth_sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:granted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      add(
        :grant_device_authorization_id,
        references(:cli_device_authorizations, type: :binary_id, on_delete: :nilify_all)
      )

      add(:granted_at, :utc_datetime_usec, null: false)
      add(:revoked_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:revoked_at, :utc_datetime_usec)

      timestamps(@ts)
    end

    create(unique_index(:cli_session_org_grants, [:auth_session_id, :org_id]))
    create(index(:cli_session_org_grants, [:org_id]))
    create(index(:cli_session_org_grants, [:auth_session_id, :revoked_at]))
    create(index(:cli_device_authorizations, [:auth_session_id]))
    create(index(:cli_device_authorizations, [:purpose]))
  end
end
