defmodule BridgeForTeams.Repo.Migrations.DailyBriefTeamChannel do
  use Ecto.Migration

  # The public Slack channel the team brief is posted to (none posts
  # nothing), and the time of day it is posted, where most members are.
  def change do
    alter table(:daily_brief_settings) do
      add :team_channel_id, :text
      add :team_post_at, :time, null: false, default: "10:20:00"
    end
  end
end
