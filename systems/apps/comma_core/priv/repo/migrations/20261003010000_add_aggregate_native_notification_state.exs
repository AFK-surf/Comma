defmodule Comma.Repo.Migrations.AddAggregateNativeNotificationState do
  use Ecto.Migration

  def change do
    alter table(:comma_notification_targets) do
      add(:activity_schema, :text)
      add(:activity_content, :map, null: false, default: %{})
      add(:activity_started_at, :utc_datetime_usec)
      add(:activity_start_pending_until, :utc_datetime_usec)
      add(:suppressed_task_ids, {:array, :text}, null: false, default: [])
      add(:router_last_sent_seq, :bigint, null: false, default: 0)
      add(:router_last_sent_badge, :integer)
    end

    drop(constraint(:comma_notification_targets, :notification_target_shape))

    create(
      constraint(:comma_notification_targets, :notification_target_shape,
        check:
          "kind IN ('device', 'live_activity', 'push_to_start') AND environment IN ('sandbox', 'production') AND ((kind = 'live_activity' AND activity_id IS NOT NULL AND ((activity_schema IS NULL AND conversation_id IS NOT NULL) OR (activity_schema = 'tasks_v1' AND conversation_id IS NULL))) OR (kind <> 'live_activity' AND conversation_id IS NULL AND activity_id IS NULL))"
      )
    )
  end
end
