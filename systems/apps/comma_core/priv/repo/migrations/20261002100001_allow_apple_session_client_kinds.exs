defmodule Comma.Repo.Migrations.AllowAppleSessionClientKinds do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")

    # Add the iPhone and paired Watch kinds to Android's check. NOT VALID keeps
    # existing sessions unscanned under the DDL lock; new writes are enforced.
    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_client_kind_valid))

    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_client_kind_valid CHECK (
      client_kind IS NULL OR
      client_kind IN ('web', 'electron', 'android', 'ios', 'watch', 'api', 'ssh')
    ) NOT VALID
    """)
  end

  def down do
    raise "Preserve iPhone and paired Watch sessions. Use a forward migration."
  end
end
