defmodule BridgeForTeams.Repo.Migrations.DailyBriefDmWithoutBundle do
  use Ecto.Migration

  # Direct messages are read when the brief is written and never stored, so
  # turning them on needs only the member's grant, not a Context Lifecycle
  # bundle to delete later.
  def up do
    drop constraint(:daily_brief_members, :daily_brief_members_dm_status)

    create constraint(:daily_brief_members, :daily_brief_members_dm_status,
             check: """
             (dm_status = 'off' AND oauth_connection_id IS NULL) OR
             (dm_status = 'on' AND oauth_connection_id IS NOT NULL) OR
             (dm_status = 'declined' AND oauth_connection_id IS NULL AND dm_declined_at IS NOT NULL)
             """
           )
  end

  def down do
    drop constraint(:daily_brief_members, :daily_brief_members_dm_status)

    create constraint(:daily_brief_members, :daily_brief_members_dm_status,
             check: """
             (dm_status = 'off' AND oauth_connection_id IS NULL) OR
             (dm_status = 'on' AND oauth_connection_id IS NOT NULL AND dm_bundle_id IS NOT NULL) OR
             (dm_status = 'declined' AND oauth_connection_id IS NULL AND dm_declined_at IS NOT NULL)
             """,
             validate: false
           )
  end
end
