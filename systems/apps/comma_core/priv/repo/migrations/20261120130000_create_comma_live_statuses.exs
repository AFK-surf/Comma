defmodule Comma.Repo.Migrations.CreateCommaLiveStatuses do
  use Ecto.Migration

  def change do
    create table(:comma_live_statuses, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:live_key, :text, null: false)
      add(:conversation_id, :text)
      add(:category, :text, null: false)
      add(:status, :text, null: false)
      add(:accent, :text, null: false, default: "auto")
      add(:title, :text, null: false)
      add(:subtitle, :text)
      add(:compact_label, :text)
      add(:eta_at, :utc_datetime_usec)
      add(:progress, :float)
      add(:step_current, :integer)
      add(:step_total, :integer)
      add(:step_label, :text)
      add(:detail_left, :text)
      add(:detail_right, :text)
      add(:alert_title, :text)
      add(:alert_body, :text)
      add(:alert_seq, :bigint, null: false, default: 0)
      add(:dismiss_after_seconds, :integer, null: false, default: 15)
      add(:version, :bigint, null: false, default: 1)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:stale_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_live_statuses, [:group_id, :live_key]))
    create(index(:comma_live_statuses, [:group_id, :status, :expires_at]))

    create table(:comma_live_status_targets, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:auth_session_id, references(:comma_auth_sessions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:live_key, :text, null: false, default: "")
      add(:token, :text, null: false)
      add(:environment, :text, null: false)
      add(:bundle_id, :text, null: false)
      add(:locale, :text, null: false, default: "en-US")
      add(:workspace_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:activity_id, :text)
      add(:activity_schema, :text, null: false, default: "live_status_v1")
      add(:activity_started_at, :utc_datetime_usec)
      add(:last_sent_version, :bigint, null: false, default: 0)
      add(:last_sent_timestamp, :bigint, null: false, default: 0)
      add(:last_sent_alert_seq, :bigint, null: false, default: 0)
      add(:last_sent_content, :map, null: false, default: %{})
      add(:pending_starts, :map, null: false, default: %{})
      add(:suppressed_keys, :map, null: false, default: %{})
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:delivery_lease_until, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_live_status_targets, [:auth_session_id, :kind, :live_key]))
    create(index(:comma_live_status_targets, [:group_id, :kind, :live_key, :id]))
    create(index(:comma_live_status_targets, [:expires_at, :id]))
  end
end
