defmodule BridgeForTeams.Repo.Migrations.AddReportsVfsPathUniqueIndex do
  @moduledoc """
  One index row per report run file, enforced by the database.

  A report run's `agent_tasks` row is keyed by the run file it indexes
  (`vfs_path`), and two writers can race to create it: the agent's
  `task_update` doorbell (BoardUpdates / TaskUpdateSink) and the
  `BridgeForTeams.Reports.Sweeper` backstop, whose indexed-paths snapshot is
  taken seconds before its insert. A partial unique index on
  `(project_id, vfs_path)` for reports rows closes that TOCTOU window — the
  loser gets a changeset error (declared via `unique_constraint` on
  `BridgeForTeams.Schema.AgentTask`) instead of a duplicate card.
  """
  use Ecto.Migration

  def up do
    # Duplicates created before this constraint existed (doorbell + sweeper
    # both indexed one run): keep the oldest row per (project, run file).
    execute("""
    DELETE FROM agent_tasks a USING agent_tasks b
    WHERE a.category = 'reports' AND b.category = 'reports'
      AND a.project_id = b.project_id
      AND a.vfs_path IS NOT NULL AND a.vfs_path = b.vfs_path
      AND (b.created_at, b.id) < (a.created_at, a.id)
    """)

    create unique_index(:agent_tasks, [:project_id, :vfs_path],
             where: "category = 'reports' AND vfs_path IS NOT NULL",
             name: :agent_tasks_reports_run_index
           )
  end

  def down do
    drop index(:agent_tasks, [:project_id, :vfs_path], name: :agent_tasks_reports_run_index)
  end
end
