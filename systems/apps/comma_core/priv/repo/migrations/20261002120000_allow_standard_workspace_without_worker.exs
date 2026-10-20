defmodule Comma.Repo.Migrations.AllowStandardWorkspaceWithoutWorker do
  use Ecto.Migration

  # A guest Workspace still has no Worker. A standard Workspace may now have
  # none: the Router creates Workers when work needs one. Existing rows keep
  # their Worker; this only relaxes the check.
  def up do
    execute("SET LOCAL lock_timeout TO '5s'")
    drop(constraint(:comma_workspaces, :comma_workspaces_kind_valid))

    execute("""
    ALTER TABLE comma_workspaces
    ADD CONSTRAINT comma_workspaces_kind_valid CHECK (
      kind IN ('standard', 'guest')
      AND (kind = 'standard' OR salix_worker_agent_id IS NULL)
    ) NOT VALID
    """)

    execute("ALTER TABLE comma_workspaces VALIDATE CONSTRAINT comma_workspaces_kind_valid")
  end

  def down do
    execute("SET LOCAL lock_timeout TO '5s'")
    drop(constraint(:comma_workspaces, :comma_workspaces_kind_valid))

    execute("""
    ALTER TABLE comma_workspaces
    ADD CONSTRAINT comma_workspaces_kind_valid CHECK (
      kind IN ('standard', 'guest')
      AND (kind = 'guest') = (salix_worker_agent_id IS NULL)
    ) NOT VALID
    """)

    execute("ALTER TABLE comma_workspaces VALIDATE CONSTRAINT comma_workspaces_kind_valid")
  end
end
