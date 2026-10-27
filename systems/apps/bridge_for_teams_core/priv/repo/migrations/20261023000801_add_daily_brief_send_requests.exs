defmodule BridgeForTeams.Repo.Migrations.AddDailyBriefSendRequests do
  use Ecto.Migration

  # An admin asks for a member's brief now; the delivery worker takes the
  # request on its next tick. The dashboard lists a Swarm's latest runs.
  def change do
    alter table(:daily_brief_members) do
      add :brief_requested_at, :utc_datetime_usec
    end

    create index(:daily_brief_runs, [:project_id, :created_at])
  end
end
