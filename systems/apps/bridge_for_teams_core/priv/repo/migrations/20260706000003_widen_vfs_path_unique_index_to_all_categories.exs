defmodule BridgeForTeams.Repo.Migrations.WidenVfsPathUniqueIndexToAllCategories do
  @moduledoc """
  One index row per VFS artifact document, enforced for every category.

  The reports-only partial index (`agent_tasks_reports_run_index`) closed the
  doorbell-vs-sweeper TOCTOU window for report runs, but the sweeper now
  backstops general artifacts too (`BridgeForTeams.Artifacts.Sweeper`, scanning
  `/.salix/artifacts/` alongside `/.salix/reports/`), and a doorbell-created
  row for an artifact file keeps the task's own category (`"metrics"`,
  `"general"`, …). Deduping by file therefore cannot be scoped to one
  category: this replaces the partial index with one on
  `(project_id, vfs_path)` for ANY row that names a file. The loser of a race
  gets a changeset error (declared via `unique_constraint` on
  `BridgeForTeams.Schema.AgentTask`) instead of a duplicate card.
  """
  use Ecto.Migration

  def up do
    drop index(:agent_tasks, [:project_id, :vfs_path], name: :agent_tasks_reports_run_index)

    # Duplicates created before this constraint covered non-report categories
    # (doorbell + sweeper both indexed one file): keep the oldest row per
    # (project, file).
    execute("""
    DELETE FROM agent_tasks a USING agent_tasks b
    WHERE a.project_id = b.project_id
      AND a.vfs_path IS NOT NULL AND a.vfs_path = b.vfs_path
      AND (b.created_at, b.id) < (a.created_at, a.id)
    """)

    create unique_index(:agent_tasks, [:project_id, :vfs_path],
             where: "vfs_path IS NOT NULL",
             name: :agent_tasks_vfs_path_index
           )
  end

  def down do
    drop index(:agent_tasks, [:project_id, :vfs_path], name: :agent_tasks_vfs_path_index)

    create unique_index(:agent_tasks, [:project_id, :vfs_path],
             where: "category = 'reports' AND vfs_path IS NOT NULL",
             name: :agent_tasks_reports_run_index
           )
  end
end
