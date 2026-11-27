defmodule BridgeForTeams.Repo.Migrations.AddDailyBriefMemberStationTaskNotified do
  use Ecto.Migration

  def change do
    alter table(:daily_brief_members) do
      add :station_task_notified, :map, null: false, default: %{}
    end
  end
end
