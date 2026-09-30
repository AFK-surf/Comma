defmodule BridgeForTeams.Repo.Migrations.ReleaseSlugOnArchivedProjects do
  use Ecto.Migration

  # Archiving is a one-way soft-delete (there is no unarchive), so an archived
  # project releases its slug: the column goes NULL and the unique(org_id, slug)
  # index no longer blocks recreating an Agent Swarm with the same name.
  def up do
    alter table(:projects) do
      modify :slug, :string, null: true
    end

    execute "UPDATE projects SET slug = NULL WHERE archived_at IS NOT NULL"
  end

  def down do
    execute "UPDATE projects SET slug = 'archived-' || id WHERE slug IS NULL"

    alter table(:projects) do
      modify :slug, :string, null: false
    end
  end
end
