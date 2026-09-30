defmodule Comma.Repo.Migrations.AddCommaAuthSessions do
  use Ecto.Migration

  def change do
    create table(:comma_auth_sessions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all), null: false)

      add(:token_hash, :binary, null: false)
      add(:auth_method, :text)
      add(:session_source, :text, null: false)
      add(:authenticated_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:revoke_reason, :text)
      add(:client_kind, :text)
      add(:device_label, :text)
      add(:user_auth_epoch, :integer, null: false)

      add(:restricted, :boolean, null: false, default: false)
      add(:workspace_id, :text)
      add(:conversation_id, :text)
      add(:interaction_budget_remaining, :integer)
      add(:tool_allowlist, {:array, :text}, null: false, default: [])
      add(:consumed_interaction_ids, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      unique_index(:comma_auth_sessions, [:token_hash], name: :comma_auth_sessions_token_hash_unique)
    )

    create(
      index(:comma_auth_sessions, [:user_id, :created_at, :id],
        name: :comma_auth_sessions_user_created_at_id_index
      )
    )

    create(
      index(:comma_auth_sessions, [:user_id, :revoked_at, :expires_at],
        name: :comma_auth_sessions_user_active_index
      )
    )

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_token_hash_length,
        check: "octet_length(token_hash) = 32"
      )
    )

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_source_method_valid,
        check: """
        (session_source = 'user_login' AND auth_method IN ('email_otp', 'google')) OR
        (session_source = 'ops_api' AND auth_method IS NULL)
        """
      )
    )

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_user_auth_epoch_valid,
        check: "user_auth_epoch >= 0"
      )
    )

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_client_kind_valid,
        check: "client_kind IS NULL OR client_kind IN ('web', 'electron', 'api')"
      )
    )

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_budget_valid,
        check: "interaction_budget_remaining IS NULL OR interaction_budget_remaining >= 0"
      )
    )

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_scope_valid,
        check: """
        (
          restricted
          AND session_source = 'ops_api'
        ) OR (
          NOT restricted
          AND workspace_id IS NULL
          AND conversation_id IS NULL
          AND interaction_budget_remaining IS NULL
          AND cardinality(tool_allowlist) = 0
          AND consumed_interaction_ids = '{}'::jsonb
        )
        """
      )
    )
  end
end
