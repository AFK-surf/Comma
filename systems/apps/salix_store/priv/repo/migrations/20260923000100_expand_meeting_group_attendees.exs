defmodule SalixStore.Repo.Migrations.ExpandMeetingGroupAttendees do
  use Ecto.Migration

  def up do
    alter table(:meeting_personal_preparations) do
      add(:source_roster_count, :integer, null: false, default: 0)
      add(:group_scan_cursor, :integer, null: false, default: 0)
      add(:group_scan_complete, :boolean, null: false, default: true)
    end

    execute("""
    UPDATE meeting_personal_preparations
    SET source_roster_count = jsonb_array_length(roster),
        group_scan_cursor = jsonb_array_length(roster)
    """)

    create table(:meeting_personal_group_memberships, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:meeting_plan_id, :text, primary_key: true)
      add(:dispatch_revision, :text, primary_key: true)
      add(:email, :text, primary_key: true)
      add(:group_email, :text, primary_key: true)
    end
  end

  def down do
    raise "group membership sources are durable; repair forward instead of dropping them"
  end
end
