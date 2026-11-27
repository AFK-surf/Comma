defmodule Comma.Repo.Migrations.AllowRaycastPairedSessions do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")

    # Add the Raycast extension's paired session to the three checks that name
    # session kinds and methods. Each check only gets wider, so no stored
    # session changes. NOT VALID keeps existing sessions unscanned under the
    # DDL lock; new writes are enforced.
    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_client_kind_valid))

    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_client_kind_valid CHECK (
      client_kind IS NULL OR
      client_kind IN ('web', 'electron', 'android', 'ios', 'watch', 'raycast', 'api', 'ssh')
    ) NOT VALID
    """)

    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_source_method_valid))

    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_source_method_valid CHECK (
      (session_source = 'user_login' AND auth_method IN ('email_otp', 'review_code', 'google', 'apple', 'watch_pairing', 'raycast_pairing', 'ssh_public_key', 'guest')) OR
      (session_source = 'ops_api' AND auth_method IS NULL) OR
      (session_source = 'channel_task_panel' AND auth_method = 'telegram_miniapp')
    ) NOT VALID
    """)

    # A paired session, and only a paired session, names the session that
    # delegated it. The constraint keeps its name, which the changeset maps.
    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_watch_parent_valid))

    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_watch_parent_valid CHECK (
      (auth_method IN ('watch_pairing', 'raycast_pairing') AND parent_session_id IS NOT NULL AND NOT restricted AND session_source = 'user_login') OR
      ((auth_method IS NULL OR auth_method NOT IN ('watch_pairing', 'raycast_pairing')) AND parent_session_id IS NULL)
    ) NOT VALID
    """)
  end

  def down do
    raise "Preserve Raycast paired sessions. Use a forward migration."
  end
end
