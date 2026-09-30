defmodule SalixStore.Repo.Migrations.IndexActiveTriagePatrolCursors do
  use Ecto.Migration

  def up do
    create(
      index(:triage_patrol_cursors, [:next_due_at, :cursor_key],
        name: :triage_patrol_cursors_active_due_idx,
        where: "last_outcome <> 'inactive'"
      )
    )

    drop(
      index(:triage_patrol_cursors, [:next_due_at, :cursor_key],
        name: :triage_patrol_cursors_due_idx
      )
    )
  end

  def down do
    create(
      index(:triage_patrol_cursors, [:next_due_at, :cursor_key],
        name: :triage_patrol_cursors_due_idx
      )
    )

    drop(
      index(:triage_patrol_cursors, [:next_due_at, :cursor_key],
        name: :triage_patrol_cursors_active_due_idx
      )
    )
  end
end
