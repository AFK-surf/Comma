defmodule BridgeForTeams.Repo.Migrations.AddDailyBriefDmBundle do
  use Ecto.Migration

  # Each direct-message enrollment registers one Context Lifecycle bundle.
  # Turning direct messages off requests that bundle's deletion.
  def change do
    alter table(:daily_brief_members) do
      add :dm_bundle_id, references(:context_bundles, type: :uuid, on_delete: :nothing)
    end

    drop constraint(:daily_brief_members, :daily_brief_members_dm_status)

    create constraint(:daily_brief_members, :daily_brief_members_dm_status,
             check: """
             (dm_status = 'off' AND oauth_connection_id IS NULL) OR
             (dm_status = 'on' AND oauth_connection_id IS NOT NULL AND dm_bundle_id IS NOT NULL) OR
             (dm_status = 'declined' AND oauth_connection_id IS NULL AND dm_declined_at IS NOT NULL)
             """
           )
  end
end
