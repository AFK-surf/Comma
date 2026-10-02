defmodule Comma.Repo.Migrations.RestoreAppleAndWatchSessionMethods do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")
    execute("SET LOCAL statement_timeout TO '300s'")

    # Add the Apple/Watch methods to guest mode's check without changing either
    # restricted-source clause or the separate Apple identity, Watch parent, and
    # capability constraints.
    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_source_method_valid))

    # Like the guest migration, enforce new writes without scanning historical
    # sessions while holding the DDL lock. No stored account/session is changed.
    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_source_method_valid CHECK (
      (session_source = 'user_login' AND auth_method IN ('email_otp', 'google', 'apple', 'watch_pairing', 'ssh_public_key', 'guest')) OR
      (session_source = 'ops_api' AND auth_method IS NULL) OR
      (session_source = 'channel_task_panel' AND auth_method = 'telegram_miniapp')
    ) NOT VALID
    """)
  end

  def down do
    raise "Preserve Apple, paired Watch, and guest sessions. Use a forward migration."
  end
end
