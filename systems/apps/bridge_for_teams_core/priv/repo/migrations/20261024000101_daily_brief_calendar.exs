defmodule BridgeForTeams.Repo.Migrations.DailyBriefCalendar do
  use Ecto.Migration

  # The organization's own calendar for the daily brief: days off on a
  # weekday, and workdays on a weekend (a holiday's make-up day).
  def change do
    alter table(:daily_brief_settings) do
      add :off_days, {:array, :date}, null: false, default: []
      add :work_days, {:array, :date}, null: false, default: []
    end
  end
end
