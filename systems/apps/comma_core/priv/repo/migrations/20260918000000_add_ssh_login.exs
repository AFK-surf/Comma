defmodule Comma.Repo.Migrations.AddSSHLogin do
  use Ecto.Migration

  def up do
    alter table(:comma_user_identities) do
      add(:public_key, :binary)
      add(:label, :text)
    end

    drop(
      index(:comma_user_identities, [:user_id, :provider],
        name: :comma_user_identities_user_provider_unique
      )
    )

    create(
      unique_index(:comma_user_identities, [:user_id, :provider],
        name: :comma_user_identities_user_provider_unique,
        where: "provider = 'google'"
      )
    )

    create(
      index(:comma_user_identities, [:user_id, :provider, :created_at],
        name: :comma_user_identities_ssh_owner_index,
        where: "provider = 'ssh'"
      )
    )

    drop(constraint(:comma_user_identities, :comma_user_identities_provider_valid))

    create(
      constraint(:comma_user_identities, :comma_user_identities_provider_valid,
        check: "provider IN ('google', 'ssh')"
      )
    )

    create(
      constraint(:comma_user_identities, :comma_user_identities_ssh_key_valid,
        check:
          "provider != 'ssh' OR (public_key IS NOT NULL AND octet_length(public_key) BETWEEN 32 AND 16384)"
      )
    )

    alter table(:comma_auth_sessions) do
      add(:login_identity_id, references(:comma_user_identities, type: :uuid, on_delete: :restrict))
    end

    create(index(:comma_auth_sessions, [:login_identity_id]))
    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_source_method_valid))

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_source_method_valid,
        check:
          "(session_source = 'user_login' AND auth_method IN ('email_otp', 'google', 'ssh_public_key')) OR (session_source = 'ops_api' AND auth_method IS NULL)"
      )
    )

    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_client_kind_valid))

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_client_kind_valid,
        check: "client_kind IS NULL OR client_kind IN ('web', 'electron', 'api', 'ssh')"
      )
    )

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_ssh_identity_required,
        check: "auth_method != 'ssh_public_key' OR login_identity_id IS NOT NULL"
      )
    )

    create table(:comma_ssh_host_keys, primary_key: false) do
      add(:name, :text, primary_key: true)
      add(:private_key_pem, :text, null: false)
    end
  end

  # SSH credentials are durable account facts. Recover forward after enrollment.
  def down, do: raise("SSH enrollment migration requires forward repair")
end
