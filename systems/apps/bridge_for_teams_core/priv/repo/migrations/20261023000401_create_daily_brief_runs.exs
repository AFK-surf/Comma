defmodule BridgeForTeams.Repo.Migrations.CreateDailyBriefRuns do
  use Ecto.Migration

  # One extraction or brief run: its window, token use, and coverage report.
  def change do
    create table(:daily_brief_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :member_id, references(:daily_brief_members, type: :binary_id, on_delete: :delete_all)
      add :kind, :text, null: false
      add :window_after, :utc_datetime_usec, null: false
      add :window_before, :utc_datetime_usec, null: false
      add :status, :text, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :coverage, :map, null: false, default: %{}
      add :notes, :map, null: false, default: %{}
      add :error, :text
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create constraint(:daily_brief_runs, :daily_brief_runs_values,
             check: """
             kind IN ('shared_extract', 'personal_extract') AND
             status IN ('completed', 'failed') AND
             ((kind = 'shared_extract' AND member_id IS NULL) OR
              (kind = 'personal_extract' AND member_id IS NOT NULL))
             """
           )

    create index(:daily_brief_runs, [:project_id, :kind, :window_before])
    create index(:daily_brief_runs, [:member_id, :window_before], where: "member_id IS NOT NULL")
  end
end
