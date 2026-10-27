defmodule BridgeForTeams.Repo.Migrations.SlimDailyBrief do
  use Ecto.Migration

  # The daily brief now keeps only its settings, members, aliases, and runs,
  # by the owner's decision. A team pass becomes a `team_brief` run. The
  # follow-up, event, scan, and direct-message tables and columns stay unused
  # until a later contract step drops them; the older run kinds stay allowed
  # until then, so a Pod of the previous release can still finish its run.
  # Direct messages were never offered, so no member reads them or holds a
  # grant or a bundle waiting for purge; one who does stops the migration.
  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM daily_brief_members
        WHERE dm_status = 'on' OR dm_bundle_id IS NOT NULL OR oauth_connection_id IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'a daily brief member still reads direct messages';
      END IF;
    END $$
    """

    drop constraint(:daily_brief_runs, :daily_brief_runs_values)

    execute "UPDATE daily_brief_runs SET kind = 'team_brief' WHERE kind = 'shared_extract'"

    create constraint(:daily_brief_runs, :daily_brief_runs_values,
             check: """
             kind IN ('team_brief', 'personal_brief', 'shared_scan', 'shared_extract',
                      'personal_extract') AND
             status IN ('running', 'pending', 'completed', 'failed') AND
             ((kind IN ('team_brief', 'shared_scan', 'shared_extract') AND member_id IS NULL) OR
              (kind IN ('personal_brief', 'personal_extract') AND member_id IS NOT NULL)) AND
             (payload_ciphertext IS NULL) = (key_version IS NULL)
             """
           )

    create unique_index(:daily_brief_runs, [:project_id],
             where: "kind = 'team_brief' AND status = 'running'",
             name: :daily_brief_runs_one_team_brief
           )
  end

  def down do
    drop index(:daily_brief_runs, [:project_id], name: :daily_brief_runs_one_team_brief)
    drop constraint(:daily_brief_runs, :daily_brief_runs_values)
    execute "UPDATE daily_brief_runs SET kind = 'shared_extract' WHERE kind = 'team_brief'"

    create constraint(:daily_brief_runs, :daily_brief_runs_values,
             check: """
             kind IN ('shared_scan', 'shared_extract', 'personal_extract', 'personal_brief') AND
             status IN ('running', 'pending', 'completed', 'failed') AND
             ((kind IN ('shared_scan', 'shared_extract') AND member_id IS NULL) OR
              (kind IN ('personal_extract', 'personal_brief') AND member_id IS NOT NULL)) AND
             (payload_ciphertext IS NULL) = (key_version IS NULL)
             """
           )
  end
end
