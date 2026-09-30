defmodule Comma.Repo.Migrations.AddChannelTaskPanelSessions do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")

    alter table(:comma_auth_sessions) do
      add(:channel_subject, :text)
      add(:channel_connect_id, :text)
    end

    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_source_method_valid))

    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_source_method_valid CHECK (
      (session_source = 'user_login' AND auth_method IN ('email_otp', 'google', 'ssh_public_key')) OR
      (session_source = 'ops_api' AND auth_method IS NULL) OR
      (session_source = 'channel_task_panel' AND auth_method = 'telegram_miniapp')
    ) NOT VALID
    """)

    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_scope_valid))

    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_scope_valid CHECK (
      (
        restricted AND session_source = 'ops_api'
        AND channel_subject IS NULL AND channel_connect_id IS NULL
        AND (conversation_id IS NULL OR group_id IS NOT NULL OR workspace_id IS NOT NULL)
      ) OR (
        restricted AND session_source = 'channel_task_panel'
        AND workspace_id IS NOT NULL AND group_id IS NOT NULL
        AND conversation_id IS NULL AND channel_subject ~ '^[1-9][0-9]{0,19}$'
        AND channel_connect_id IS NOT NULL AND length(channel_connect_id) BETWEEN 1 AND 200
        AND interaction_budget_remaining IS NULL AND cardinality(tool_allowlist) = 0
        AND consumed_interaction_ids = '{}'::jsonb
      ) OR (
        NOT restricted AND channel_subject IS NULL AND channel_connect_id IS NULL
        AND workspace_id IS NULL AND group_id IS NULL AND conversation_id IS NULL
        AND interaction_budget_remaining IS NULL AND cardinality(tool_allowlist) = 0
        AND consumed_interaction_ids = '{}'::jsonb
      )
    ) NOT VALID
    """)
  end

  def down, do: raise("Channel Task panel sessions require forward repair")
end
