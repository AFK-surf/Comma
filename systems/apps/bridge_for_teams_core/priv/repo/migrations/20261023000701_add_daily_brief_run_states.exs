defmodule BridgeForTeams.Repo.Migrations.AddDailyBriefRunStates do
  use Ecto.Migration

  # A team pass holds a `running` row while it works, so a second Pod skips it.
  # A rendered brief waits as `pending` with its sealed content until Slack
  # accepts it, so a failed send is retried without running the model again.
  def change do
    alter table(:daily_brief_runs) do
      add :payload_ciphertext, :text
      add :key_version, :integer
    end

    drop constraint(:daily_brief_runs, :daily_brief_runs_values)

    create constraint(:daily_brief_runs, :daily_brief_runs_values,
             check: """
             kind IN ('shared_extract', 'personal_extract', 'personal_brief') AND
             status IN ('running', 'pending', 'completed', 'failed') AND
             ((kind = 'shared_extract' AND member_id IS NULL) OR
              (kind IN ('personal_extract', 'personal_brief') AND member_id IS NOT NULL)) AND
             (payload_ciphertext IS NULL) = (key_version IS NULL)
             """
           )

    create unique_index(:daily_brief_runs, [:project_id],
             where: "kind = 'shared_extract' AND status = 'running'",
             name: :daily_brief_runs_one_team_pass
           )

    create unique_index(:daily_brief_runs, [:member_id],
             where: "kind = 'personal_brief' AND status = 'pending'",
             name: :daily_brief_runs_one_pending_brief
           )
  end
end
