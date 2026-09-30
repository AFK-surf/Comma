defmodule BridgeForTeams.Repo.Migrations.ProjectAclRoles do
  use Ecto.Migration

  def up do
    execute("UPDATE project_memberships SET role = 'user' WHERE role IN ('member', 'viewer')")
  end

  def down do
    execute("UPDATE project_memberships SET role = 'member' WHERE role = 'user'")
  end
end
