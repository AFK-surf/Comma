defmodule Comma.Repo.Migrations.AddAuthSessionNotificationTargets do
  use Ecto.Migration

  def change do
    create table(:comma_notification_targets, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:auth_session_id, references(:comma_auth_sessions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:token, :text, null: false)
      add(:environment, :text, null: false)
      add(:workspace_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:conversation_id, :text)
      add(:activity_id, :text)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:last_sent_version, :bigint, null: false, default: 0)
      add(:last_sent_status, :text)
      add(:recent_states, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_notification_targets, [:auth_session_id, :kind]))
    create(index(:comma_notification_targets, [:group_id, :conversation_id, :id]))
    create(index(:comma_notification_targets, [:group_id, :id]))
    create(index(:comma_notification_targets, [:expires_at, :id]))

    create(
      constraint(:comma_notification_targets, :notification_target_shape,
        check:
          "kind IN ('device', 'live_activity', 'push_to_start') AND environment IN ('sandbox', 'production') AND ((kind = 'live_activity' AND conversation_id IS NOT NULL AND activity_id IS NOT NULL) OR (kind <> 'live_activity' AND conversation_id IS NULL AND activity_id IS NULL))"
      )
    )
  end
end
