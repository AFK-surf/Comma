defmodule Comma.Repo.Migrations.AddReviewLoginCode do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")

    alter table(:comma_users) do
      add(:review_login_code_hash, :text)
    end

    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_source_method_valid))

    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_source_method_valid CHECK (
      (session_source = 'user_login' AND auth_method IN ('email_otp', 'review_code', 'google', 'apple', 'watch_pairing', 'ssh_public_key', 'guest')) OR
      (session_source = 'ops_api' AND auth_method IS NULL) OR
      (session_source = 'channel_task_panel' AND auth_method = 'telegram_miniapp')
    ) NOT VALID
    """)
  end

  def down,
    do: raise("Preserve configured review credentials and sessions. Use a forward migration.")
end
