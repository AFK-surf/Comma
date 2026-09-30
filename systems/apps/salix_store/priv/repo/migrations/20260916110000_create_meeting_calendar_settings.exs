defmodule SalixStore.Repo.Migrations.CreateMeetingCalendarSettings do
  use Ecto.Migration

  def change do
    create table(:meeting_calendar_settings, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:connect_id, :text, null: false)
      add(:enabled, :boolean, null: false)
      add(:configuration, :map, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:meeting_calendar_settings, [:connect_id]))
    create(index(:meeting_calendar_settings, [:enabled, :group_id]))
  end
end
