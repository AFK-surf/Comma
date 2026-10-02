defmodule Comma.Repo.Migrations.AllowAndroidSessionClientKind do
  use Ecto.Migration

  def up do
    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_client_kind_valid))

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_client_kind_valid,
        check:
          "client_kind IS NULL OR client_kind IN ('web', 'electron', 'android', 'api', 'ssh')"
      )
    )
  end

  def down do
    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_client_kind_valid))

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_client_kind_valid,
        check: "client_kind IS NULL OR client_kind IN ('web', 'electron', 'api', 'ssh')"
      )
    )
  end
end
