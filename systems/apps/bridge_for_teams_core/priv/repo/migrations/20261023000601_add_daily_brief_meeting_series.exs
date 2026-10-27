defmodule BridgeForTeams.Repo.Migrations.AddDailyBriefMeetingSeries do
  use Ecto.Migration

  # Follow-ups from minutes remember their meeting series, so the next
  # meeting's notice can show the previous meeting's commitments.
  def change do
    alter table(:daily_brief_followups) do
      add :meeting_series, :text
      add :meeting_id, :text
    end

    create index(:daily_brief_followups, [:project_id, :meeting_series, :opened_at],
             where: "meeting_series IS NOT NULL"
           )
  end
end
