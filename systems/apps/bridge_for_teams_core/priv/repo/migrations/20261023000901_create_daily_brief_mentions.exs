defmodule BridgeForTeams.Repo.Migrations.CreateDailyBriefMentions do
  use Ecto.Migration

  # The shared scan reads each window of a Swarm's public channels once and
  # records, per member, which messages concern them: references only, the
  # text stays in the Salix Slack mirror. A member's pass reads just those.
  def change do
    create table(:daily_brief_mentions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :member_id, references(:daily_brief_members, type: :binary_id, on_delete: :delete_all),
        null: false

      add :conversation_id, :text, null: false
      add :ts, :text, null: false
      add :tier, :text, null: false
      add :reasons, {:array, :text}, null: false, default: []
      add :observed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create constraint(:daily_brief_mentions, :daily_brief_mentions_tier,
             check: "tier IN ('p0', 'p1')"
           )

    create unique_index(:daily_brief_mentions, [:member_id, :conversation_id, :ts])
    create index(:daily_brief_mentions, [:member_id, :observed_at])
    create index(:daily_brief_mentions, [:observed_at])

    drop constraint(:daily_brief_runs, :daily_brief_runs_values)

    create constraint(:daily_brief_runs, :daily_brief_runs_values,
             check: """
             kind IN ('shared_scan', 'shared_extract', 'personal_extract', 'personal_brief') AND
             status IN ('running', 'pending', 'completed', 'failed') AND
             ((kind IN ('shared_scan', 'shared_extract') AND member_id IS NULL) OR
              (kind IN ('personal_extract', 'personal_brief') AND member_id IS NOT NULL)) AND
             (payload_ciphertext IS NULL) = (key_version IS NULL)
             """
           )

    # When each Swarm's stream was last scanned, so the worker takes the
    # longest-waiting Swarms first.
    alter table(:daily_brief_settings) do
      add :shared_scanned_at, :utc_datetime_usec
    end

    create index(:daily_brief_settings, [:shared_scanned_at], where: "enabled")

    create unique_index(:daily_brief_runs, [:project_id],
             where: "kind = 'shared_scan' AND status = 'running'",
             name: :daily_brief_runs_one_shared_scan
           )
  end
end
