defmodule BridgeForTeams.Repo.Migrations.AddProviderAwareSsoIdentities do
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def up do
    alter table(:users) do
      modify :email, :citext, null: true
    end

    alter table(:org_sso_connections) do
      add_if_not_exists :provider, :string, null: false, default: "generic_oidc"
      add_if_not_exists :provider_config, :map, null: false, default: %{}
      add_if_not_exists :last_verified_at, :utc_datetime_usec
      add_if_not_exists :last_error_code, :string
      modify :issuer, :string, null: true
    end

    execute("""
    DELETE FROM org_sso_connections a
    USING org_sso_connections b
    WHERE a.org_id = b.org_id
      AND (
        a.updated_at < b.updated_at
        OR (a.updated_at = b.updated_at AND a.id::text < b.id::text)
      )
    """)

    drop_if_exists unique_index(:org_sso_connections, [:org_id, :issuer])
    drop_if_exists index(:org_sso_connections, [:org_id])
    create_if_not_exists unique_index(:org_sso_connections, [:org_id])

    create_if_not_exists table(:org_sso_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :provider_subject_type, :string, null: false
      add :provider_subject, :string, null: false
      add :email, :citext
      add :mobile, :string
      add :display_name, :string
      add :provider_profile, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime_usec

      timestamps(@ts)
    end

    create_if_not_exists unique_index(
                           :org_sso_identities,
                           [
                             :org_id,
                             :provider,
                             :provider_subject_type,
                             :provider_subject
                           ],
                           name: :org_sso_identities_provider_subject_index
                         )

    create_if_not_exists index(:org_sso_identities, [:user_id])
    create_if_not_exists index(:org_sso_identities, [:org_id, :provider])
  end

  def down do
    drop_if_exists table(:org_sso_identities)

    drop_if_exists unique_index(:org_sso_connections, [:org_id])
    create index(:org_sso_connections, [:org_id])
    create unique_index(:org_sso_connections, [:org_id, :issuer])

    alter table(:org_sso_connections) do
      modify :issuer, :string, null: false
      remove_if_exists :last_error_code
      remove_if_exists :last_verified_at
      remove_if_exists :provider_config
      remove_if_exists :provider
    end

    alter table(:users) do
      modify :email, :citext, null: false
    end
  end
end
