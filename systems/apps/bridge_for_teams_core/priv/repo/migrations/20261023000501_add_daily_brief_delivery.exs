defmodule BridgeForTeams.Repo.Migrations.AddDailyBriefDelivery do
  use Ecto.Migration

  # A delivered brief is a run of its own, with the follow-ups it showed and
  # the member's answers to them.
  def change do
    alter table(:daily_brief_members) do
      add :brief_claimed_at, :utc_datetime_usec
    end

    alter table(:daily_brief_runs) do
      add :slack_channel_id, :text
      add :slack_ts, :text
    end

    drop constraint(:daily_brief_runs, :daily_brief_runs_values)

    create constraint(:daily_brief_runs, :daily_brief_runs_values,
             check: """
             kind IN ('shared_extract', 'personal_extract', 'personal_brief') AND
             status IN ('completed', 'failed') AND
             ((kind = 'shared_extract' AND member_id IS NULL) OR
              (kind IN ('personal_extract', 'personal_brief') AND member_id IS NOT NULL))
             """
           )

    create table(:daily_brief_refs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:daily_brief_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :followup_id,
          references(:daily_brief_followups, type: :binary_id, on_delete: :delete_all),
          null: false

      add :section, :text, null: false
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:daily_brief_refs, [:run_id, :followup_id])
    create index(:daily_brief_refs, [:followup_id])

    create table(:daily_brief_feedback, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :member_id, references(:daily_brief_members, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:daily_brief_runs, type: :binary_id, on_delete: :nilify_all)

      add :followup_id,
          references(:daily_brief_followups, type: :binary_id, on_delete: :nilify_all)

      add :action, :text, null: false
      add :stage, :text, null: false
      add :note_ciphertext, :text
      add :key_version, :integer
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create constraint(:daily_brief_feedback, :daily_brief_feedback_values,
             check: """
             action IN ('done', 'not_mine', 'snooze', 'missed', 'dm_declined') AND
             stage IN ('coverage', 'identify', 'understand', 'track') AND
             (note_ciphertext IS NULL) = (key_version IS NULL)
             """
           )

    create index(:daily_brief_feedback, [:member_id, :created_at])
  end
end
